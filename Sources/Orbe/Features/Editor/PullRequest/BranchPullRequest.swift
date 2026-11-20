import Foundation

/// worktree の今の PR が見せる PR か、その PR の状態が変わったことを受ける者（PR のパネル）。
@MainActor
protocol BranchPullRequestObserver: AnyObject {
  func branchPullRequestDidChange(_ pullRequest: BranchPullRequest)
}

/// worktree の今の PR——今のブランチから出ている open の PR はどれか（無ければ作成の入口の材料、出せなければその理由）と、
/// PR があるときの手元とのずれ。worktree の根（正準形）ごとに 1 つで、アプリが動いている間持つ。PR そのものの中身は PR
/// ごとの状態（`PullRequestState`）が持つ——ブランチを切り替えても、開いている PR の diff タブはその PR を見続ける。
///
/// GitHub に問い合わせるのは見ている者（`beginWatching`）がいる間だけ。読み直すきっかけは、誰も見ていない状態から
/// 見ている者が現れた・`reload`・今のブランチ名が変わった・Orbe の中のネット操作が終わった・リモート追跡の ref が動き、
/// このブランチの push 先の追跡 ref か PR のベースブランチの追跡 ref の値が前と変わった、のどれか。読んでいる間に次の
/// きっかけが来たら、終わった後に 1 回だけ読み直す。手元の HEAD が動いただけなら、GitHub に問い合わせずに手元とのずれと
/// 作成の入口の先行の数を数え直す。
@MainActor @Observable
final class BranchPullRequest {
  let root: String
  @ObservationIgnored let source: PullRequestSource
  private(set) var answer = Answer.reading
  /// 手元とのずれ（PR が無い・数え終わっていないなら nil）。
  private(set) var drift: Drift?
  /// PR を保ったまま、今のブランチの PR を引き直せなかった理由（問い合わせの失敗・GitHub のどのリポジトリか確かめられ
  /// ない）。次に答えを出したら消える。
  private(set) var lookupFailure: Unavailable?

  @ObservationIgnored private var files: RootFiles?
  @ObservationIgnored private var watchers = 0
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
  /// 作成の入口の先行の数を数える、既定のブランチの追跡 ref（既定のブランチが remote に無ければ nil）。
  @ObservationIgnored private var defaultTrackingRef: String?
  /// ずれを数えた（数えている）手元の HEAD と PR の先頭。
  @ObservationIgnored private var counted: (local: String, pullRequest: String)?
  @ObservationIgnored private var observers: [WeakObserver] = []

  private struct WeakObserver {
    weak var value: BranchPullRequestObserver?
  }

  private static var registry: [String: BranchPullRequest] = [:]

  /// 根 `root`（正準形）の今の PR。無ければ `source` で作る。
  static func shared(for root: String, source: PullRequestSource) -> BranchPullRequest {
    if let live = registry[root] { return live }
    let pullRequest = BranchPullRequest(root: root, source: source)
    registry[root] = pullRequest
    return pullRequest
  }

  private init(root: String, source: PullRequestSource) {
    self.root = root
    self.source = source
  }

  /// 今の PR の状態（PR があるときだけ）。
  var state: PullRequestState? {
    if case .pullRequest(let state) = answer { return state }
    return nil
  }

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

  /// 見ている者が現れた。誰も見ていなかったなら、根のサービスを握って観測し、読み直す（見ている者が増えただけなら、
  /// 読み直さない）。
  func beginWatching() {
    watchers += 1
    guard watchers == 1 else { return }
    let files = RootFiles.shared(for: root)
    self.files = files
    files.addObserver(self)
    SourceControl.shared(for: root).addObserver(self)
    state?.addObserver(self)
    state?.beginWatching()
    reload()
  }

  /// 見ている者が去った。最後の 1 人なら根のサービスを手放す。
  func endWatching() {
    guard watchers > 0 else { return }
    watchers -= 1
    guard watchers == 0 else { return }
    files?.removeObserver(self)
    files = nil
    SourceControl.shared(for: root).removeObserver(self)
    state?.removeObserver(self)
    state?.endWatching()
  }

  /// 読み直す——今のブランチの PR を引き直す。PR の中身は、PR ごとの状態が自分のきっかけで読み直す。
  func reload() {
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
    // この問い合わせは、動いた後の GitHub を読む。
    tracking.record { [weak self] in
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
          creation(
            ref, name: name, defaultBranch: defaultBranch, remoteDefault: remoteDefault, repo)
        }
      }
    }
  }

  /// PR が無いブランチの作成の入口の材料——既定のブランチに対する先行の数を数え、ブランチが GitHub に在るかを問い合わせる。
  private func creation(
    _ ref: GitHubBranchRef, name: String, defaultBranch: String, remoteDefault: String,
    _ repo: GitRepo
  ) {
    defaultTrackingRef = remoteDefault.contains("/") ? "refs/remotes/" + remoteDefault : nil
    countAhead(in: repo) { [weak self] ahead in
      guard let self else { return }
      let creation = Creation(
        branch: name, defaultBranch: defaultBranch, ahead: ahead,
        url: ref.pullRequestCreationURL, published: .checking)
      // この読みが答えを出したときだけ問い合わせる（見ている者がいなくなった・ブランチが変わったなら、答えを出していない）。
      guard let settled = finish(.noPullRequest(creation), name), settled == settlement else {
        return
      }
      source.branchExists(ref) { [weak self] exists in
        guard let self, settlement == settled, case .noPullRequest(var current) = answer else {
          return
        }
        switch exists {
        case .success(true): current.published = .yes
        case .success(false): current.published = .no
        case .failure: current.published = .unknown
        }
        answer = .noPullRequest(current)
      }
    }
  }

  /// 既定のブランチの追跡 ref に対する、手元の HEAD の先行の数（追跡 ref が無い・数えられなければ nil）。
  private func countAhead(in repo: GitRepo, _ done: @escaping (Int?) -> Void) {
    guard let defaultTrackingRef else { return done(nil) }
    repo.counts("HEAD", against: defaultTrackingRef) { done($0?.ahead) }
  }

  /// 作成の入口を出している間に手元の HEAD が動いた——GitHub に問い合わせずに先行の数を数え直す（数えた時点の答えが
  /// 変わっていなければ入れる）。
  func recountAhead() {
    guard case .noPullRequest = answer, let repo = files?.repo else { return }
    let settled = settlement
    countAhead(in: repo) { [weak self] ahead in
      guard let self, settlement == settled, case .noPullRequest(var current) = answer,
        current.ahead != ahead
      else { return }
      current.ahead = ahead
      answer = .noPullRequest(current)
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
      reload()
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

  /// 答えを `next` にする。PR が替われば、前の PR を見るのをやめ、今の PR を見て（誰も見ていなかった PR なら、PR ごとの状態が
  /// 中身を読み直す）、受ける者へ知らせる。
  private func settle(_ next: Answer) {
    settlement += 1
    lookupFailure = nil
    let previous = state
    if answer != next { answer = next }
    let current = state
    if previous !== current {
      previous?.removeObserver(self)
      previous?.endWatching()
      current?.addObserver(self)
      current?.beginWatching()
      counted = nil
      notify()
    }
    countDrift()
  }

  private static func unavailable(_ reason: GitHubBranchPullRequestsUnavailable) -> Unavailable {
    switch reason {
    case .ghMissing: .ghMissing
    case .ghUnauthed: .ghUnauthed
    case .notGitHub: .notGitHub
    case .unverified: .unverified
    }
  }

  /// PR が置かれたリポジトリ `repository` を指す remote（台帳の中で正式名が等しいもの。名前の順で最初）。
  private static func remote(of repository: GitHubRepoName, in ledger: GitHubRemoteLedger.Resolved?)
    -> String?
  {
    (ledger?.repositories ?? [:]).filter { $0.value == .github(repository) }.keys.sorted().first
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
