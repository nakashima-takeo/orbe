import CoreServices
import Foundation

/// 根と git dir の変化を FSEvents で拾い、デバウンスして 1 バッチにまとめる。linked worktree では
/// index・HEAD が本体側（gitDir / commonDir）に在るので、根だけでなくそれらも監視する。
///
/// FSEvents が返すパスは実パス（`/private/var/…`）で、根は正規形（`/var/…`）。監視開始時に各 root の
/// 実パスを 1 回求め、イベントのパスをその root の綴りへ付け替える（通知のパスは呼び手の綴りで揃う）。
final class RepoWatcher {
  /// デバウンス後に届く変化のまとめ。
  struct Batch: Equatable {
    /// 変わったパス（root の綴りの絶対パス）。git dir の中は含まない。
    var paths: Set<String> = []
    /// git dir の中で状態（index・HEAD・refs・merge / rebase の進行状態）が変わった。
    var gitChanged = false
    /// 取りこぼし（イベントの drop・root の付け替え）。全部見直す。
    var scanAll = false

    var isEmpty: Bool { paths.isEmpty && !gitChanged && !scanAll }
  }

  /// 連続するイベントの間はこれだけ待つ。
  static let debounce: TimeInterval = 0.2
  /// 最初の保留からこれだけ経てば、続いていても出す（ビルド中に永遠に出ないことがない）。
  static let maximumDelay: TimeInterval = 1.0

  private var stream: FSEventStreamRef?
  private let onChange: (Batch) -> Void
  /// 監視する場所（呼び手の綴りと実パス）。付け替えは最長一致で行う（根の中の `.git` は git dir が勝つ）。
  private let watched: [(spelling: String, real: String)]
  private let gitDirs: [String]
  private var pending = Batch()
  private var trailing: DispatchWorkItem?
  private var deadline: DispatchWorkItem?

  /// - Parameters:
  ///   - roots: 監視するディレクトリ（根・gitDir・commonDir）。
  ///   - gitDirs: このうち git dir であるもの（中の churn を index・HEAD・refs に絞る）。
  init?(roots: [String], gitDirs: [String], onChange: @escaping (Batch) -> Void) {
    self.onChange = onChange
    // 長い方から当てる——linked worktree の gitDir は commonDir の中にあり、自分の私有状態は自分の
    // gitDir 側で拾い、commonDir 側に落ちる `worktrees/` は他人のものとして弾ける。
    self.gitDirs = gitDirs.sorted { $0.count > $1.count }
    var seen: Set<String> = []
    watched = roots.compactMap { root in
      let real = Self.realPath(root)
      guard seen.insert(real).inserted else { return nil }
      return (root, real)
    }
    .sorted { $0.real.count > $1.real.count }

    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
      let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
      watcher.handle(
        paths: Array(list.prefix(count)),
        flags: Array(UnsafeBufferPointer(start: flags, count: count)))
    }
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, watched.map(\.real) as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot))
    else { return nil }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, .main)
    FSEventStreamStart(stream)
  }

  deinit {
    trailing?.cancel()
    deadline?.cancel()
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
  }

  private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
    var batch = pending
    for (path, flag) in zip(paths, flags) {
      if flag & Self.scanAllFlags != 0 {
        batch.scanAll = true
        batch.gitChanged = true
        continue
      }
      let spelled = respell(path)
      if let gitDir = gitDirs.first(where: { spelled.hasPrefix($0 + "/") }) {
        if Self.isGitStateChange(String(spelled.dropFirst(gitDir.count))) {
          batch.gitChanged = true
        }
      } else if !spelled.contains("/.git/"), !spelled.hasSuffix("/.git") {
        batch.paths.insert(spelled)
      }
    }
    guard !batch.isEmpty else { return }
    schedule(batch)
  }

  private static let scanAllFlags = FSEventStreamEventFlags(
    kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
      | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)

  /// git dir の中で status・baseline に関係しないもの。objects（multi-pack-index を含む）・reflog・
  /// 他の worktree と submodule の私有状態・各種 `.lock` は弾き、それ以外（index・HEAD・refs・packed-refs・
  /// reftable・merge / rebase / sequencer の進行状態と、git が今後足す状態ファイル）は拾う——
  /// 拾う側を列挙すると未知のファイルが取りこぼし側に倒れる。
  private static let ignoredGitDirEntries: Set<Substring> = [
    "objects", "logs", "worktrees", "modules",
  ]

  /// `sub` は git dir からの相対パス（`/` 始まり）。先頭の構成要素で弾く（その要素自身の出入りも含む）。
  private static func isGitStateChange(_ sub: String) -> Bool {
    guard !sub.hasSuffix(".lock") else { return false }
    let first = sub.dropFirst().split(
      separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    return !ignoredGitDirEntries.contains(first.first ?? "")
  }

  /// 後追い 200ms、ただし最初の保留から 1s で強制。
  private func schedule(_ batch: Batch) {
    let first = pending.isEmpty
    pending = batch
    trailing?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.flush() }
    trailing = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    if first {
      let limit = DispatchWorkItem { [weak self] in self?.flush() }
      deadline = limit
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.maximumDelay, execute: limit)
    }
  }

  private func flush() {
    trailing?.cancel()
    deadline?.cancel()
    trailing = nil
    deadline = nil
    let batch = pending
    pending = Batch()
    guard !batch.isEmpty else { return }
    onChange(batch)
  }

  /// 実パスで届いたイベントを、その場所の呼び手の綴りへ付け替える。
  private func respell(_ path: String) -> String {
    for place in watched where path == place.real || path.hasPrefix(place.real + "/") {
      return place.spelling + path.dropFirst(place.real.count)
    }
    return path
  }

  private static func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
