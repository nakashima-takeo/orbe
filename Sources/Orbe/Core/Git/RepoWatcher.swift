import CoreServices
import Foundation

/// チェックアウトの変化を FSEvents で監視し、デバウンスして通知する。
/// worktree のファイル編集と git 状態（index・HEAD・refs）の両方を拾う。
/// linked worktree では index 等が本体リポジトリ側に在るため、
/// worktree root だけでなく gitDir / commonDir も監視対象に含める。
final class RepoWatcher {
  private var stream: FSEventStreamRef?
  private let onChange: () -> Void
  private var pending: DispatchWorkItem?
  private let gitDirs: [String]

  /// - Parameters:
  ///   - roots: 監視するディレクトリ（worktree root・gitDir・commonDir）。
  ///   - gitDirs: このうち git dir であるもの（内部 churn のフィルタに使う）。
  init?(roots: [String], gitDirs: [String], onChange: @escaping () -> Void) {
    self.onChange = onChange
    self.gitDirs = gitDirs

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
      let pathList = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
      watcher.handle(paths: Array(pathList.prefix(Int(count))))
    }
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context,
        Array(Set(roots)) as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.1,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
    else { return nil }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, .main)
    FSEventStreamStart(stream)
  }

  deinit {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
  }

  private func handle(paths: [String]) {
    guard paths.contains(where: { isRelevant($0) }) else { return }
    // 連続イベント（保存・git 操作の lock 騒ぎ）を 1 回のリフレッシュに畳む。
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.onChange() }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
  }

  /// git dir 内部は index・HEAD・refs・merge 進行系だけが関心事
  /// （objects や各種 lock の churn でリフレッシュを空回しさせない）。
  private func isRelevant(_ path: String) -> Bool {
    guard let gitDir = gitDirs.first(where: { path.hasPrefix($0) }) else {
      // worktree 側。ただし root 直下の .git（ファイル/ディレクトリ実体）経由の
      // イベントは gitDir 判定に倒す。
      return !path.contains("/.git/")
    }
    let sub = String(path.dropFirst(gitDir.count))
    if sub.hasSuffix(".lock") { return false }
    return sub.contains("index") || sub.contains("HEAD") || sub.contains("/refs")
      || sub.contains("MERGE") || sub.contains("rebase")
  }
}
