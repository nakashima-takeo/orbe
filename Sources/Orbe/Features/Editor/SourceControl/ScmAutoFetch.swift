import AppKit

/// リポジトリの裏の fetch の係。そのリポジトリのエディター面が見えていて設定がオンの面（欲しがる面）があり、Orbe が
/// 前面にある間、前回の fetch・pull の終わりから `ScmAutoFetchRules.interval` ごとに裏で fetch する（ソース管理パネルを
/// 出しているかに依らない）。共通の git dir（正準形）ごとに 1 つで、アプリが動いている間持つ——同じリポジトリの worktree は
/// remote 追跡 ref を共有し、並んだ fetch・pull は後の側が落ちる。
///
/// 裏の fetch は worktree の操作の列（`SourceControl`）に載らないので、帯・失敗の文・ボタンの可否に出ない。先行・遅れが
/// 新しく見えるのは、ref が動いた後の監視が、そのリポジトリの見えている根に届くから。人のネット操作は、走っている裏の
/// fetch を止め、その終わりを待ってから起こす（譲る）——止める手の完了を待たずに起こすと、remote 追跡 ref の更新で後の側が
/// 落ちる。いつ撃つか・終わりで何を記録するかは `ScmAutoFetchRules` が決め、係は時計と git の呼び出しだけを持つ。
@MainActor
final class ScmAutoFetch {
  private struct Wanting {
    weak var panel: ScmPanel?
  }

  private final class Yielded {
    let start: () -> Void

    init(_ start: @escaping () -> Void) {
      self.start = start
    }
  }

  /// 共通の git dir（正準形）。
  let key: String
  private(set) var rules: ScmAutoFetchRules
  /// 走っている裏の fetch の止める手。
  private var running: RootFiles.Write?
  /// 裏の fetch の終わりを待っている人の操作の 1 段目。
  private var yielded: [Yielded] = []
  private var wanting: [Wanting] = []
  private var timer: DispatchWorkItem?

  private static var registry: [String: ScmAutoFetch] = [:]
  private static var activation: [NSObjectProtocol] = []

  /// `repo` のリポジトリの係。無ければ作る。
  static func shared(for repo: GitRepo) -> ScmAutoFetch {
    let key = GitWorktreeRoot.normalizedPath(repo.commonDir)
    if let live = registry[key] { return live }
    observeActivation()
    let fetcher = ScmAutoFetch(key: key, isAppActive: NSApplication.shared.isActive)
    registry[key] = fetcher
    return fetcher
  }

  private init(key: String, isAppActive: Bool) {
    self.key = key
    rules = ScmAutoFetchRules(isAppActive: isAppActive)
  }

  /// Orbe が前面に戻れば予約し直し（時刻を過ぎていればすぐ撃つ）、背後へ回れば予約を捨てる。窓が背後にあるだけ（Orbe の
  /// 別の窓を使っている）なら止めない。
  private static func observeActivation() {
    guard activation.isEmpty else { return }
    let center = NotificationCenter.default
    activation = [
      NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
    ]
    .map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          for fetcher in registry.values {
            fetcher.rules.isAppActive = name == NSApplication.didBecomeActiveNotification
            fetcher.schedule()
          }
        }
      }
    }
  }

  // MARK: - 欲しがる面

  /// 面 `panel` が欲しがる（面が見えていて、根の git dir が分かり、設定がオン）かを決め直した。
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

  /// 人のネット操作が始まった。届け出ている間は裏の fetch を撃たない（走っているものは、ネットの段の前の `yield` が
  /// 止める）。終わりは `humanDidFinish` で必ず 1 回届ける。
  func humanWillStart() {
    cancelTimer()
    rules.humanWillStart()
  }

  /// 人の操作のネットの段を起こす前に譲る。裏の fetch が走っていれば止め、その終わりを待ってから `start` を呼び、待ちを
  /// 取り下げる手を返す（取り下げた `start` は呼ばない）。走っていなければ `start` を呼ばずに nil を返す（そのまま起こせる）。
  func yield(then start: @escaping () -> Void) -> (() -> Void)? {
    guard rules.isRunning else { return nil }
    let waiting = Yielded(start)
    yielded.append(waiting)
    running?.cancel()
    return { [weak self] in self?.yielded.removeAll { $0 === waiting } }
  }

  /// 人のネット操作が終わった。
  func humanDidFinish(_ kind: SourceControl.Kind, _ failure: GitWriteFailure?) {
    rules.humanDidFinish(kind, failure, at: Date())
    schedule()
  }

  // MARK: - 予約と裏の fetch

  /// 撃てる間は、次の fetch を規則の間の後に予約する（過ぎていればすぐ）。撃てなくなったら予約を捨てる（走っている裏の
  /// fetch は止めない）。時刻は壁の時計で数える（スリープの間も進む）。
  private func schedule() {
    cancelTimer()
    rules.isWanted = wanting.contains { $0.panel != nil }
    guard let delay = rules.delay(at: Date()) else { return }
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
    guard !rules.isRunning, rules.humans == 0,
      let files = wanting.lazy.compactMap({ $0.panel?.liveFiles }).first
    else { return }
    rules.backgroundDidStart()
    running = files.fetch(
      unattended: true, onProgress: { _ in },
      completion: { [weak self] failure in self?.backgroundDidFinish(failure) })
  }

  /// 裏の fetch が終わった。待っていた人の操作を起こし、予約し直す。
  private func backgroundDidFinish(_ failure: GitWriteFailure?) {
    running = nil
    rules.backgroundDidFinish(failure, at: Date())
    let starts = yielded.map(\.start)
    yielded = []
    for start in starts { start() }
    schedule()
  }
}

/// 裏の fetch の係の判断（時刻を引数で受ける状態機械）——いつ撃つか、終わりで何を記録するか。
struct ScmAutoFetchRules {
  /// 前回の fetch・pull の終わりから次の裏の fetch までの間。
  static let interval: TimeInterval = 180

  /// 前回の fetch・pull（裏・手）が通った、または裏の fetch が認証・ホスト鍵以外で落ちた時刻。まだ無ければ、撃てるように
  /// なったらすぐ撃つ。
  private(set) var lastFinished: Date?
  /// 裏の fetch が走っている。
  private(set) var isRunning = false
  /// 認証・ホスト鍵の失敗で止まっている（手の push・pull・fetch が通るまで）。
  private(set) var isBlocked = false
  /// 走っている（譲られるのを待っているものを含む）人のネット操作の数。
  private(set) var humans = 0
  /// Orbe が前面か。
  var isAppActive: Bool
  /// 欲しがる面があるか。
  var isWanted = false

  init(isAppActive: Bool) {
    self.isAppActive = isAppActive
  }

  /// 次の裏の fetch を撃つまでの間（nil なら撃たない）。欲しがる面があり、Orbe が前面で、止まっておらず、人の操作も裏の
  /// fetch も走っていなければ、前回の終わり＋`interval` まで（過ぎていれば 0）。
  func delay(at now: Date) -> TimeInterval? {
    guard isWanted, isAppActive, !isBlocked, humans == 0, !isRunning else { return nil }
    guard let lastFinished else { return 0 }
    return max(0, lastFinished.addingTimeInterval(Self.interval).timeIntervalSince(now))
  }

  mutating func backgroundDidStart() {
    isRunning = true
  }

  /// 人のネット操作が始まった。
  mutating func humanWillStart() {
    humans += 1
  }

  /// 人のネット操作が終わった。fetch・pull・同期が通れば前回の時刻を今にして止まりを解き、push の類が通れば止まりだけを
  /// 解く（remote 追跡 ref の全体は新しくならない）。
  mutating func humanDidFinish(
    _ kind: SourceControl.Kind, _ failure: GitWriteFailure?, at now: Date
  ) {
    humans -= 1
    guard failure == nil else { return }
    switch kind {
    case .fetch, .pull, .sync:
      lastFinished = now
      isBlocked = false
    case .push, .publish, .commitAndPush:
      isBlocked = false
    default:
      break
    }
  }

  /// 裏の fetch が終わった。認証・ホスト鍵の失敗なら止まり、止めた（人に譲った）なら時刻を変えず、ほかは通っても落ちても
  /// 前回の時刻を今にする（落ちたら黙って次の周期を待つ）。
  mutating func backgroundDidFinish(_ failure: GitWriteFailure?, at now: Date) {
    isRunning = false
    switch failure {
    case .cancelled?: break
    case .authentication?, .unknownHostKey?: isBlocked = true
    default: lastFinished = now
    }
  }
}
