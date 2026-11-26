import AppKit

/// worktree の今の PR が見せる PR か、その PR の状態が変わったことを受ける者（PR のパネル）。
@MainActor
protocol BranchPullRequestObserver: AnyObject {
  func branchPullRequestDidChange(_ pullRequest: BranchPullRequest)
}

/// worktree の今の PR——今のブランチから出ている open の PR はどれか（無ければ作成の入口の材料、出せなければその理由）と、
/// PR があるときの手元とのずれ。worktree の根（正準形）ごとに 1 つで、アプリが動いている間持つ。PR そのものの中身は PR
/// ごとの状態（`PullRequestState`）が持つ。
///
/// 見ている者は 2 段——どの PR かだけを追う者（`beginTracking`）と、PR の中身も読む者（`beginWatching`）。GitHub に
/// 問い合わせるのは、どちらかがいる間だけ。PR ごとの状態を見る（中身・スレッド・両端を読む）のと、PR が無いときの作成の
/// 入口の材料（ブランチが GitHub に在るか）を読むのは、中身も読む者がいる間だけ。
///
/// 今のブランチの PR を引き直すきっかけは、誰も見ていない状態から見ている者が現れた・`reload`・今のブランチ名が変わった・
/// Orbe の中のネット操作が終わった・リモート追跡の ref が動き、このブランチの push 先の追跡 ref か PR のベースブランチの
/// 追跡 ref の値が前と変わった・Orbe が前面に戻った、のどれか。読んでいる間に次のきっかけが来たら、終わった後に 1 回だけ
/// 読み直す。引いた PR が今と同じなら何も替えず、PR が無いままなら答えも通し番号も替えない。作成の入口の材料は、材料が古い
/// ときだけ読み直す——材料を古くするのは、Orbe が前面に戻ったこと以外のきっかけと、引き直す前に覚え直した追跡 ref の値が
/// 前と違っていたこと。読み直している間は前の値を出したまま。手元の HEAD が動いただけなら、GitHub に問い合わせずに手元との
/// ずれを数え直す。
@MainActor @Observable
final class BranchPullRequest {
  let root: String
  @ObservationIgnored let source: PullRequestSource
  private(set) var answer = Answer.reading { didSet { readingFailuresDidChange() } }
  /// 手元とのずれ（PR が無い・数え終わっていないなら nil）。
  private(set) var drift: Drift?
  /// PR を保ったまま、今のブランチの PR を引き直せなかった失敗（理由は、問い合わせの失敗か、GitHub のどのリポジトリか
  /// 確かめられない）。次に答えを出したら消える。
  private(set) var lookupFailure: Unavailable? { didSet { readingFailuresDidChange() } }
  /// 人が「GitHub から読めていない」知らせを閉じたときの PR の状態（→ `+ReadingFailure`）。
  weak var readingFailureDismissedState: PullRequestState?

  @ObservationIgnored private var files: RootFiles?
  /// どの PR かだけを追う者と、中身も読む者の数。
  @ObservationIgnored private var trackers = 0
  @ObservationIgnored private var readers = 0
  /// 作成の入口の材料（ブランチが GitHub に在るか）が今の答えに追いついていない（まだ読んでいないも含む）。
  @ObservationIgnored private var publishedIsStale = true
  /// ブランチが GitHub に在るかを問い合わせている最中。
  @ObservationIgnored private var isCheckingPublished = false
  @ObservationIgnored private var isReading = false
  @ObservationIgnored private var readAgain = false
  /// 読み直しを、status が届くまで待っている（届いたら、ブランチ名が前と同じでも読み直す）。
  @ObservationIgnored var awaitingStatus = false
  /// 答えを出した通し番号（`settle` のたびに増える）。答えに続く問い合わせの結果は、その答えを出した番号のままのときだけ
  /// 入れる——答えの値が同じでも、別の読みが出した答えには入れない。
  @ObservationIgnored private var settlement = 0
  /// 答えを出している・読んでいるブランチ名（ブランチに居ない・git の管理下でないなら nil）・手元の HEAD。
  @ObservationIgnored var branch: String?
  @ObservationIgnored var head: String?
  /// このブランチの push 先の追跡 ref と、PR のベースブランチの追跡 ref（PR の中身が読めていれば）。
  @ObservationIgnored lazy var tracking = TrackingRefs { [weak self] done in
    guard let self else { return }
    trackedRefs(done)
  }
  /// ずれを数えた（数えている）手元の HEAD と PR の先頭。
  @ObservationIgnored private var counted: (local: String, pullRequest: String)?
  @ObservationIgnored private var observers: [WeakObserver] = []

  private struct WeakObserver {
    weak var value: BranchPullRequestObserver?
  }

  private static var registry: [String: BranchPullRequest] = [:]

  /// Orbe が前面に戻った通知の観測（アプリ全体で 1 つ）。
  private static var activation: NSObjectProtocol?

  /// 根 `root`（正準形）の今の PR。無ければ `source` で作る。
  static func shared(for root: String, source: PullRequestSource) -> BranchPullRequest {
    if let live = registry[root] { return live }
    observeActivation()
    let pullRequest = BranchPullRequest(root: root, source: source)
    registry[root] = pullRequest
    return pullRequest
  }

  private init(root: String, source: PullRequestSource) {
    self.root = root
    self.source = source
  }

  /// 今の PR の状態（PR があるときだけ）。
  var state: PullRequestState? { if case .pullRequest(let state) = answer { state } else { nil } }

  func addObserver(_ observer: BranchPullRequestObserver) {
    observers.removeAll { $0.value == nil || $0.value === observer }
    observers.append(WeakObserver(value: observer))
  }

  func removeObserver(_ observer: BranchPullRequestObserver) {
    observers.removeAll { $0.value == nil || $0.value === observer }
  }

  func notify() {
    for observer in observers { observer.value?.branchPullRequestDidChange(self) }
  }

  // MARK: - 見ている者

  /// どの PR かだけを追う者・中身も読む者の合計。
  private var watchers: Int { trackers + readers }

  /// どの PR かだけを追う者が現れた。誰も見ていなかったなら、根のサービスを握って観測し、読み直す。
  func beginTracking() {
    trackers += 1
    if watchers == 1 { startObserving() }
  }

  /// どの PR かだけを追う者が去った。誰もいなくなれば根のサービスを手放す。
  func endTracking() {
    guard trackers > 0 else { return }
    trackers -= 1
    if watchers == 0 { stopObserving() }
  }

  /// 中身も読む者が現れた。最初の 1 人なら今の PR の状態を見始め、PR が無い答えなら古い材料を読む。誰も見ていなかったなら、
  /// 根のサービスを握って観測し、読み直す。
  func beginWatching() {
    readers += 1
    guard readers == 1 else { return }
    state?.addObserver(self)
    state?.beginWatching()
    if watchers == 1 { startObserving() } else { checkPublishedIfStale() }
  }

  /// 中身も読む者が去った。最後の 1 人なら今の PR の状態を見るのをやめ、誰もいなくなれば根のサービスを手放す。
  func endWatching() {
    guard readers > 0 else { return }
    readers -= 1
    guard readers == 0 else { return }
    state?.removeObserver(self)
    state?.endWatching()
    if watchers == 0 { stopObserving() }
  }

  private func startObserving() {
    let files = RootFiles.shared(for: root)
    self.files = files
    files.addObserver(self)
    SourceControl.shared(for: root).addObserver(self)
    reload()
  }

  private func stopObserving() {
    files?.removeObserver(self)
    files = nil
    SourceControl.shared(for: root).removeObserver(self)
  }

  /// Orbe が前面に戻ったら、見ている者がいる今の PR だけが、今のブランチの PR を引き直す（作成の入口の材料は古くしない）。
  private static func observeActivation() {
    guard activation == nil else { return }
    activation = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        for pullRequest in registry.values where pullRequest.watchers > 0 {
          pullRequest.lookUpPullRequest()
        }
      }
    }
  }

  /// 読み直す——作成の入口の材料を古くして、今のブランチの PR を引き直す。PR の中身は、PR ごとの状態が自分のきっかけで
  /// 読み直す。
  func reload() {
    publishedIsStale = true
    lookUpPullRequest()
  }

  /// 今のブランチの PR を引き直す。
  private func lookUpPullRequest() {
    guard watchers > 0, let files else { return }
    awaitingStatus = false
    guard files.isResolved else { return }
    guard let repo = files.repo else {
      branch = nil
      return settle(.unavailable(.notGit))
    }
    guard let status = files.status else {
      awaitingStatus = true
      return
    }
    guard let name = status.branch?.name else {
      branch = nil
      return settle(.unavailable(.detached))
    }
    head = status.branch?.commit
    if name != branch {
      branch = name
      settle(.reading)
    }
    if isReading {
      readAgain = true
      return
    }
    isReading = true
    // 問い合わせる前の追跡 ref の値を覚えてから問い合わせる——覚えた後に動けば比べて読み直し、覚える前に動いたなら、
    // この問い合わせは、動いた後の GitHub を読む。前に覚えた値と違えば、ブランチが GitHub に在るかが変わりうる。
    tracking.record { [weak self] moved in
      if moved { self?.publishedIsStale = true }
      repo.defaultBranch { [weak self] remoteDefault in
        self?.lookUp(name, in: repo, remoteDefault: remoteDefault)
      }
    }
  }

  private func lookUp(_ name: String, in repo: GitRepo, remoteDefault: String) {
    // 追跡 ref と既定のブランチを読む間に見ている者がいなくなったら、GitHub に問い合わせない。
    guard watchers > 0 else { return stopReading() }
    let defaultBranch = GitBranch.localName(fromRemote: remoteDefault)
    guard name != defaultBranch else {
      finish(.unavailable(.defaultBranch), name)
      return
    }
    source.branchPullRequests(repo, name) { [weak self] found in
      guard let self else { return }
      switch found.branches[name] {
      case nil: failed(.failed(.reason("")), name)
      case .unavailable(.unverified)?: failed(.unverified, name)
      case .unavailable(let reason)?: finish(.unavailable(Self.unavailable(reason)), name)
      case .gitHub(_, .failure(let reason))?: failed(.failed(reason), name)
      case .gitHub(let ref, .success(let pullRequests))?:
        let open = pullRequests.first { $0.state == "OPEN" }
        if let id = open?.url.flatMap(GitHubItemID.init(pullRequestURL:)) {
          let state = PullRequestState.shared(
            for: PullRequestState.Key(commonDir: repo.commonDir, id: id), source: source)
          state.attach(
            repo: repo, fetchRemote: Self.remote(of: id.repo, in: found.ledger),
            headRemote: Self.remote(of: ref.repo, in: found.ledger))
          finish(.pullRequest(state), name)
        } else {
          noPullRequest(ref, name: name)
        }
      }
    }
  }

  /// open の PR が無い。前の答えも同じブランチの「無い」なら、答えも通し番号も替えない。どちらでも、材料が古ければ読む。
  private func noPullRequest(_ ref: GitHubBranchRef, name: String) {
    if case .noPullRequest(let current) = answer, current.branch == name, current.ref == ref {
      finish(nil, name)
    } else {
      let creation = Creation(branch: name, ref: ref, published: .checking)
      // この読みが答えを出したときだけ材料を読む（見ている者がいなくなった・ブランチが変わったなら、答えを出していない）。
      guard let settled = finish(.noPullRequest(creation), name), settled == settlement else {
        return
      }
      publishedIsStale = true
    }
    checkPublishedIfStale()
  }

  /// 作成の入口の材料（ブランチが GitHub に在るか）が古ければ問い合わせる——中身も読む者がいて、答えが PR の無いことのとき
  /// だけ。問い合わせは 1 本ずつで、その間に材料が古くなったり答えが替わったりしたら、結果を入れずに読み直す。
  private func checkPublishedIfStale() {
    guard readers > 0, publishedIsStale, !isCheckingPublished,
      case .noPullRequest(let creation) = answer
    else { return }
    publishedIsStale = false
    isCheckingPublished = true
    let settled = settlement
    source.branchExists(creation.ref) { [weak self] exists in
      guard let self else { return }
      isCheckingPublished = false
      if settlement == settled, !publishedIsStale, case .noPullRequest(var current) = answer {
        switch exists {
        case .success(true): current.published = .yes
        case .success(false): current.published = .no
        case .failure: current.published = .unknown
        }
        if answer != .noPullRequest(current) { answer = .noPullRequest(current) }
      }
      checkPublishedIfStale()
    }
  }

  /// 読み終えた。読んでいる間にブランチが変わっていれば答えを捨てる（前のブランチの答えは出さない）。ブランチが
  /// 変わっていたか、きっかけが来ていれば読み直す。答えを出したなら、その答えの通し番号を返す。`next` が nil なら、今の
  /// 答えを保つ。
  @discardableResult
  private func finish(_ next: Answer?, _ name: String) -> Int? {
    // 読んでいる間に見ている者がいなくなったら、答えは出さない（PR の状態を見始めない。次に見ている者が現れたら読み直す）。
    guard watchers > 0 else {
      stopReading()
      return nil
    }
    isReading = false
    let current = files?.status?.branch?.name
    var settled: Int?
    if name == current, let next {
      settle(next)
      settled = settlement
    }
    if readAgain || name != current {
      readAgain = false
      lookUpPullRequest()
    }
    return settled
  }

  /// 引き直しが失敗した（問い合わせの失敗・確かめられない）。PR を引けていれば、答えを替えずに PR を保ち（PR の状態を
  /// 見続ける）、理由だけを持つ——一時的な失敗のたびに PR が消えて、PR の中身の追従が止まらないように。PR を引けて
  /// いなければ、出せない理由にする。
  private func failed(_ reason: Unavailable, _ name: String) {
    // 問い合わせの最中に見ている者がいなくなったら、答えも理由も出さない。
    guard watchers > 0 else { return stopReading() }
    guard case .pullRequest = answer else {
      finish(.unavailable(reason), name)
      return
    }
    finish(nil, name)
    if case .pullRequest = answer { lookupFailure = reason }
  }

  /// 見ている者がいなくなったので、答えを出さずに読むのをやめる（積んだ読み直しも捨てる）。
  private func stopReading() {
    isReading = false
    readAgain = false
  }

  /// 答えを `next` にする。PR が替われば、中身も読む者がいる間は前の PR を見るのをやめて今の PR を見て（誰も見ていなかった
  /// PR なら、PR ごとの状態が中身を読み直す）、受ける者へ知らせる。
  private func settle(_ next: Answer) {
    settlement += 1
    lookupFailure = nil
    let previous = state
    if answer != next { answer = next }
    let current = state
    if previous !== current {
      if readers > 0 {
        previous?.removeObserver(self)
        previous?.endWatching()
        current?.addObserver(self)
        current?.beginWatching()
      }
      counted = nil
      notify()
    }
    countDrift()
  }

  // MARK: - 手元とのずれ

  /// 手元の HEAD と PR の先頭の間で、手元とのずれを数える（PR の中身が読めた後。diff の両端には依らない。数えた組と同じ
  /// なら数え直さない）。浅いクローンでは数えず、手元の HEAD が PR の先頭と同じなら一致、違えば違うことだけを持つ——
  /// マージベースが求まっても、git は浅い境界の先をたどれず、数が誤りうる（浅くなくなった後、次に PR の状態か手元の HEAD
  /// が変わったときに数え直す）。PR の先頭のコミットが手元に無い・読めないなら、違うことだけを持ち、次に PR の状態か手元の
  /// HEAD が変わったときに数え直す（両端を求めるために取ってきた後に数えられる）。
  func countDrift() {
    guard let prHead = state?.content?.headCommit else {
      counted = nil
      drift = nil
      return
    }
    let local = head
    if let counted, counted.local == local, counted.pullRequest == prHead { return }
    guard let local, let repo = files?.repo else {
      counted = nil
      drift = .differs
      return
    }
    guard !repo.isShallow else {
      counted = nil
      drift = local == prHead ? .inSync : .differs
      return
    }
    counted = (local, prHead)
    repo.counts(local, against: prHead) { [weak self] counts in
      guard let self, counted?.local == local, counted?.pullRequest == prHead else { return }
      guard let counts else {
        counted = nil
        drift = .differs
        return
      }
      drift =
        counts.ahead == 0 && counts.behind == 0
        ? .inSync : .diverged(ahead: counts.ahead, behind: counts.behind)
    }
  }

  // MARK: - 追跡 ref

  /// このブランチの push 先の追跡 ref と、PR のベースブランチの追跡 ref（PR の中身が読めていれば）の名前。
  private func trackedRefs(_ completion: @escaping ((repo: GitRepo, refs: [String])?) -> Void) {
    guard let repo = files?.repo, let branch else { return completion(nil) }
    repo.pushTracking(ofBranch: branch) { [weak self] push in
      guard let self else { return }
      var refs: [String] = []
      if case .ref(let ref)? = push { refs.append(ref) }
      if let base = state?.baseTrackingRef { refs.append(base) }
      completion((repo, refs))
    }
  }
}
