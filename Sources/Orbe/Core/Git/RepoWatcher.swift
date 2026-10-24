import CoreServices
import Foundation

/// 根と git dir の変化を FSEvents で拾い、デバウンスして 1 バッチにまとめる。linked worktree では
/// index・HEAD が本体側（gitDir / commonDir）に在るので、根だけでなくそれらも監視する。
///
/// 入れ子の git dir（サブモジュールの `.git/modules/<名前>` と作業ツリーの中の `<sub>/.git`、入れ子のリポジトリの
/// `.git`）の状態の変化も拾い、親の git の状態とは別の事実として出す——中のコミット・checkout・index の書き換えは親の
/// status（サブモジュールの行）を変えるが、親の ref・HEAD・index は動かさない。
///
/// FSEvents が返すパスは実パス（`/private/var/…`）で、根は正規形（`/var/…`）。監視開始時に各 root の
/// 実パスを 1 回求め、イベントのパスをその root の綴りへ付け替える（通知のパスは呼び手の綴りで揃う）。
final class RepoWatcher {
  /// デバウンス後に届く変化のまとめ。
  struct Batch: Equatable {
    /// 変わったパス（root の綴りの絶対パス）。git dir の中は含まない。
    var paths: Set<String> = []
    /// 監視している git dir の中で状態が変わった（分け方は `gitDirChange`）。
    var gitChanged = false
    /// 入れ子の git dir の中で状態が変わった（分け方は `gitDirChange`・`nestedGitDirChange`）。
    var nestedGitChanged = false
    /// 取りこぼし（イベントの drop・root の付け替え）。全部見直す。
    var scanAll = false
    /// git の状態のうち remote 追跡 ref が動いたかもしれない（`gitChanged` の一部。何をそう見るかは
    /// `isRemoteRefChange`）。
    var remoteRefsChanged = false

    var isEmpty: Bool { paths.isEmpty && !gitChanged && !nestedGitChanged && !scanAll }

    mutating func merge(_ other: Batch) {
      paths.formUnion(other.paths)
      gitChanged = gitChanged || other.gitChanged
      nestedGitChanged = nestedGitChanged || other.nestedGitChanged
      scanAll = scanAll || other.scanAll
      remoteRefsChanged = remoteRefsChanged || other.remoteRefsChanged
    }
  }

  private var stream: FSEventStreamRef?
  private let onChange: (Batch) -> Void
  /// 監視する場所（呼び手の綴りと実パス）。付け替えは最長一致で行う（linked worktree の gitDir は
  /// commonDir の中にある）。
  private let watched: [(spelling: String, real: String)]
  private let gitDirs: [String]
  private var debounce = BatchDebounce()
  /// `debounce.dueDate` に張った 1 本のタイマー。
  private var timer: DispatchWorkItem?

  /// - Parameters:
  ///   - roots: 監視するディレクトリ（根・gitDir・commonDir）。
  ///   - gitDirs: このうち git dir であるもの（中の変化を状態ファイルに絞る規則は `gitDirChange`）。
  ///     linked worktree では自分の gitDir と commonDir の両方を渡す——最長一致で、commonDir 側の
  ///     `worktrees/` を他人の私有状態として弾ける。
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
    FSEventStreamSetDispatchQueue(stream, .main)
    // queue への登録の失敗は start の戻り値でしか分からない。捨てると「監視が張れた」と信じたまま
    // イベントが 1 件も来ない。start していない stream に Stop は呼べない。
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return nil
    }
    self.stream = stream
  }

  deinit {
    timer?.cancel()
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
  }

  private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
    var batch = Batch()
    for (path, flag) in zip(paths, flags) {
      if flag & Self.scanAllFlags != 0 {
        batch.scanAll = true
        batch.gitChanged = true
        batch.nestedGitChanged = true
        batch.remoteRefsChanged = true
        continue
      }
      let spelled = respell(path)
      if let gitDir = gitDirs.first(where: { spelled.hasPrefix($0 + "/") }) {
        switch Self.gitDirChange(String(spelled.dropFirst(gitDir.count))) {
        case .state(let remoteRefs):
          batch.gitChanged = true
          if remoteRefs { batch.remoteRefsChanged = true }
        case .nested: batch.nestedGitChanged = true
        case nil: break
        }
      } else if let dotGit = spelled.range(of: "/.git/") {
        // 根より深い `<dir>/.git/` の下は入れ子の git dir。根自身の `.git/` は git dir の監視が受け持つので捨てる。
        let owner = spelled[..<dotGit.lowerBound]
        if !watched.contains(where: { $0.spelling == owner }),
          Self.gitDirChange(String(spelled[dotGit.lowerBound...].dropFirst("/.git".count))) != nil
        {
          batch.nestedGitChanged = true
        }
      } else if !spelled.hasSuffix("/.git") {
        batch.paths.insert(spelled)
      }
    }
    guard !batch.isEmpty else { return }
    arm(at: debounce.note(batch, at: Date()))
  }

  private static let scanAllFlags = FSEventStreamEventFlags(
    kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
      | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)

  /// git dir の中の変化の分け方。
  enum GitDirChange: Equatable {
    /// その git dir の状態が変わった。`remoteRefs` は remote 追跡 ref が動いたかもしれないか（`isRemoteRefChange`）。
    case state(remoteRefs: Bool)
    /// その git dir の下にある入れ子の git dir（`modules/` の下のサブモジュール）の状態が変わった。
    case nested
  }

  /// git dir の中で status・版の本文に関係しないもの。objects（multi-pack-index を含む）・reflog・
  /// 他の worktree の私有状態・各種 `.lock` は弾き、それ以外（index・HEAD・refs・packed-refs・reftable・
  /// merge / rebase / sequencer の進行状態と、git が今後足す状態ファイル）は拾う——拾う側を列挙すると
  /// 未知のファイルが取りこぼし側に倒れる。
  ///
  /// **git 自身の読み取りが生む副産物も弾く**: fsmonitor デーモン（`core.fsmonitor`）は git が読むたびに
  /// `fsmonitor--daemon/cookies/<pid>-<n>` を作って消す（`--no-optional-locks` でも抑止されない）。
  /// 拾うと自分の status が自分を呼び戻し、根を開いている限り git が回り続ける。
  private static let ignoredGitDirEntries: Set<Substring> = [
    "objects", "logs", "worktrees", "fsmonitor--daemon", "fsmonitor--daemon.ipc",
  ]

  /// `sub` は git dir からの相対パス（`/` 始まり）。先頭の構成要素で弾く（その要素自身の出入りも含む）。`modules` の下は
  /// サブモジュールの git dir で、`nestedGitDirChange` で分ける。
  static func gitDirChange(_ sub: String) -> GitDirChange? {
    guard !sub.hasSuffix(".lock") else { return nil }
    let head = sub.dropFirst().prefix { $0 != "/" }
    if head == "modules" { return nestedGitDirChange(sub) }
    guard !ignoredGitDirEntries.contains(head) else { return nil }
    return .state(remoteRefs: isRemoteRefChange(sub))
  }

  /// `modules/` の下（`sub` は外側の git dir からの相対パス）。サブモジュールの名前は `/` を含めるので、どこからが
  /// サブモジュールの git dir かをパスだけでは決められない——名前の最初の段（`modules/` の直後。必ず名前）を除き、どの深さの
  /// 要素でも同じ表で弾く。名前の 2 段目以降にその語の要素があると取りこぼす。ブランチ名にその語の要素があっても、普通の
  /// コミット・`reset --soft` は git dir の直下の index・ORIG_HEAD も書くので拾える。
  private static func nestedGitDirChange(_ sub: String) -> GitDirChange? {
    let components = sub.split(separator: "/").dropFirst(2)
    return components.contains(where: ignoredGitDirEntries.contains) ? nil : .nested
  }

  /// git の状態の変化 `sub`（git dir からの相対パス）で remote 追跡 ref が動いたかもしれないか——`refs/remotes` の下と、
  /// どの ref が動いたかを名前で分けられない packed-refs・reftable。HEAD・ローカルのブランチ・タグ・index・FETCH_HEAD は
  /// remote 追跡 ref ではない。
  static func isRemoteRefChange(_ sub: String) -> Bool {
    sub.hasPrefix("/refs/remotes/") || sub == "/refs/remotes" || sub == "/packed-refs"
      || sub == "/reftable" || sub.hasPrefix("/reftable/")
  }

  /// タイマーを `due` に張り直す（常に 1 本）。
  private func arm(at due: Date) {
    timer?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.fire() }
    timer = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + max(0, due.timeIntervalSinceNow), execute: work)
  }

  private func fire() {
    timer = nil
    if let batch = debounce.flush(at: Date()) {
      onChange(batch)
    } else if let due = debounce.dueDate {
      arm(at: due)
    }
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
