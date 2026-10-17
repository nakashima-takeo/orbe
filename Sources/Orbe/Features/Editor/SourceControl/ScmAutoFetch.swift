import AppKit

/// リポジトリの裏の fetch の係。そのリポジトリのソース管理パネルを出していて設定がオンの面（欲しがる面）があり、Orbe が
/// 前面にある間、前回の fetch・pull の終わりから `interval` ごとに裏で fetch する。共通の git dir（正準形）ごとに 1 つで、
/// アプリが動いている間持つ——同じリポジトリの worktree は remote 追跡 ref を共有し、並んだ fetch・pull は後の側が落ちる。
///
/// 裏の fetch は worktree の操作の列（`SourceControl`）に載らないので、帯・失敗の文・ボタンの可否に出ない。先行・遅れが
/// 新しく見えるのは、ref が動いた後の監視が、そのリポジトリの見えている根に届くから。失敗は黙って次の周期を待ち、認証・
/// ホスト鍵の失敗なら、手のネット操作が通るまで止まる。人のネット操作は、走っている裏の fetch を止め、その終わりを待って
/// から起こす（譲る）——止める手の完了を待たずに起こすと、remote 追跡 ref の更新で後の側が落ちる。
@MainActor
final class ScmAutoFetch {
  /// 前回の fetch・pull の終わりから次の裏の fetch までの間。
  static let interval: TimeInterval = 180

  /// 今の時刻と、Orbe が前面か（テストが差し替える）。
  struct Clock {
    var now: () -> Date
    var isAppActive: () -> Bool
  }

  static var clock = Clock(now: Date.init, isAppActive: { NSApplication.shared.isActive })

  private struct Wanting {
    weak var panel: ScmPanel?
  }

  /// 共通の git dir（正準形）。
  let key: String
  /// 前回の fetch・pull（裏・手）が終わった時刻。まだ無ければ、欲しがられたらすぐ撃つ。
  private var lastFinished: Date?
  /// 走っている裏の fetch の止める手。
  private var running: RootFiles.Write?
  /// 裏の fetch の終わりを待っている人の操作の 1 段目。
  private var yielded: [() -> Void] = []
  /// 認証・ホスト鍵の失敗で止まっている（手の push・pull・fetch が通るまで）。
  private var isBlocked = false
  /// 走っている（譲られるのを待っているものを含む）人のネット操作の数。
  private var humans = 0
  private var wanting: [Wanting] = []
  private var timer: DispatchWorkItem?

  private static var registry: [String: ScmAutoFetch] = [:]
  private static var activation: [NSObjectProtocol] = []

  /// `repo` のリポジトリの係。無ければ作る。
  static func shared(for repo: GitRepo) -> ScmAutoFetch {
    let key = GitWorktreeRoot.normalizedPath(repo.commonDir)
    if let live = registry[key] { return live }
    observeActivation()
    let fetcher = ScmAutoFetch(key: key)
    registry[key] = fetcher
    return fetcher
  }

  private init(key: String) {
    self.key = key
  }

  /// Orbe が前面に戻れば予約し直し（時刻を過ぎていればすぐ撃つ）、背後へ回れば予約を捨てる。窓が背後にあるだけ（Orbe の
  /// 別の窓を使っている）なら止めない。
  private static func observeActivation() {
    guard activation.isEmpty else { return }
    let center = NotificationCenter.default
    activation = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
      .map { name in
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated {
            for fetcher in registry.values { fetcher.schedule() }
          }
        }
      }
  }

  // MARK: - 欲しがる面

  /// 面 `panel` が欲しがる（パネルを出していて、根の git dir が分かり、設定がオン）かを決め直した。
  func setWanted(_ wanted: Bool, by panel: ScmPanel) {
    wanting.removeAll { $0.panel == nil }
    let isWanting = wanting.contains { $0.panel === panel }
    guard wanted != isWanting else { return }
    if wanted {
      wanting.append(Wanting(panel: panel))
    } else {
      wanting.removeAll { $0.panel === panel }
    }
    schedule()
  }

  // MARK: - 人の操作

  /// 人のネット操作を始める。走っている裏の fetch があれば止め、その終わりを待ってから `start`（1 段目）を呼ぶ。終わりは
  /// `humanDidFinish` で必ず 1 回届ける（待つ間に止められた操作も）。
  func yield(then start: @escaping () -> Void) {
    humans += 1
    cancelTimer()
    guard let running else { return start() }
    yielded.append(start)
    running.cancel()
  }

  /// 人のネット操作が終わった。fetch・pull・同期が通れば前回の時刻を今にして止まりを解き、push の類が通れば止まりだけを
  /// 解く（remote 追跡 ref の全体は新しくならない）。人の操作が 0 に戻れば予約し直す。
  func humanDidFinish(_ kind: SourceControl.Kind, _ failure: GitWriteFailure?) {
    humans -= 1
    if failure == nil {
      switch kind {
      case .fetch, .pull, .sync:
        lastFinished = Self.clock.now()
        isBlocked = false
      case .push, .publish, .commitAndPush:
        isBlocked = false
      default:
        break
      }
    }
    schedule()
  }

  // MARK: - 予約と裏の fetch

  /// 欲しがる面があり、Orbe が前面で、止まっておらず、人の操作も裏の fetch も走っていなければ、次の fetch を「前回の終わり
  /// ＋ `interval`」に予約する（過ぎていればすぐ）。条件が崩れたら予約を捨てる（走っている裏の fetch は止めない）。時刻は
  /// 壁の時計で数える（スリープの間も進む）。
  private func schedule() {
    cancelTimer()
    guard running == nil, humans == 0, !isBlocked, Self.clock.isAppActive(),
      wanting.contains(where: { $0.panel != nil })
    else { return }
    let now = Self.clock.now()
    let delay =
      lastFinished.map { max(0, $0.addingTimeInterval(Self.interval).timeIntervalSince(now)) } ?? 0
    let item = DispatchWorkItem { [weak self] in self?.fire() }
    timer = item
    DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: item)
  }

  private func cancelTimer() {
    timer?.cancel()
    timer = nil
  }

  /// 欲しがっている面の根のサービスで、裏の fetch を撃つ。
  private func fire() {
    timer = nil
    guard running == nil, humans == 0,
      let files = wanting.lazy.compactMap({ $0.panel?.liveFiles }).first
    else { return }
    running = files.fetch(unattended: true, onProgress: { _ in }) { [weak self] failure in
      self?.backgroundDidFinish(failure)
    }
  }

  /// 裏の fetch が終わった。通れば前回の時刻を今に、認証・ホスト鍵の失敗なら止まる、ほかの失敗は黙って時刻だけ進める、
  /// 止めた（人に譲った）なら時刻を変えない。待っていた人の操作を起こし、予約し直す。
  private func backgroundDidFinish(_ failure: GitWriteFailure?) {
    running = nil
    switch failure {
    case .cancelled?: break
    case .authentication?, .unknownHostKey?: isBlocked = true
    default: lastFinished = Self.clock.now()
    }
    let starts = yielded
    yielded = []
    for start in starts { start() }
    schedule()
  }
}
