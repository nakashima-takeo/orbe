import Foundation

/// worktree の今の PR——今のブランチから出ている open の PR はどれか（無ければ作成の入口の材料、出せなければその理由）と、
/// PR があるときの手元とのずれ。worktree の根（正準形）ごとに 1 つで、アプリが動いている間持つ。PR そのものの中身は PR
/// ごとの状態（`PullRequestState`）が持つ——ブランチを切り替えても、開いている PR の diff タブはその PR を見続ける。
///
/// GitHub に問い合わせるのは見ている者（`beginWatching`）がいる間だけ。読み直すきっかけは、見ている者が現れた・`reload`・
/// 今のブランチ名が変わった・Orbe の中のネット操作が終わった・リモート追跡の ref が動いて、このブランチの push 先の追跡
/// ref か PR のベースブランチの追跡 ref の値が前と変わった、のどれか。読んでいる間に次のきっかけが来たら、終わった後に
/// 1 回だけ読み直す。手元の HEAD が動いただけなら、GitHub に問い合わせずに手元とのずれを数え直す。
@MainActor @Observable
final class BranchPullRequest {
  /// 出せない理由。
  enum Unavailable: Equatable {
    case notGit
    case detached
    case defaultBranch
    case ghMissing
    case ghUnauthed
    case notGitHub
    case unverified
    case failed(GitHubFailure)
  }

  /// ブランチが GitHub に在るか。
  enum Published: Equatable {
    case checking
    case yes
    case no
    /// 問い合わせが失敗した。
    case unknown
  }

  /// open の PR が無いときの、作成の入口の材料。
  struct Creation: Equatable {
    let branch: String
    let defaultBranch: String
    /// 既定のブランチの追跡 ref に対する先行の数（追跡 ref が手元に無ければ nil）。
    let ahead: Int?
    let url: URL?
    let ref: GitHubBranchRef
    var published: Published
  }

  enum Answer: Equatable {
    case reading
    case unavailable(Unavailable)
    case noPullRequest(Creation)
    case pullRequest(PullRequestState)

    static func == (lhs: Answer, rhs: Answer) -> Bool {
      switch (lhs, rhs) {
      case (.reading, .reading): true
      case (.unavailable(let a), .unavailable(let b)): a == b
      case (.noPullRequest(let a), .noPullRequest(let b)): a == b
      case (.pullRequest(let a), .pullRequest(let b)): a === b
      default: false
      }
    }
  }

  /// PR があるときの手元とのずれ。
  enum Drift: Equatable {
    /// この worktree で PR の先頭をチェックアウト済み。
    case inSync
    /// 手元にしか無いコミット（未 push）の数と、PR にしか無いコミット（未取得）の数。
    case diverged(ahead: Int, behind: Int)
    /// PR の両端を取れず数えられないが、手元の HEAD が PR の先頭と違う。
    case differs
  }

  let root: String
  @ObservationIgnored let source: PullRequestSource
  private(set) var answer = Answer.reading
  /// 手元とのずれ（PR が無い・数え終わっていないなら nil）。
  private(set) var drift: Drift?

  @ObservationIgnored private var files: RootFiles?
  @ObservationIgnored private var watchers = 0
  @ObservationIgnored private var isReading = false
  @ObservationIgnored private var readAgain = false
  /// 最後に引いたブランチ名・手元の HEAD・追跡 ref の値。
  @ObservationIgnored private var branch: String?
  @ObservationIgnored private var head: String?
  @ObservationIgnored private var tracked: [String: String]?
  /// ずれを数えた手元の HEAD と PR の先頭。
  @ObservationIgnored private var counted: (local: String?, pullRequest: String)?

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

  // MARK: - 見ている者

  /// 見ている者が現れた。最初の 1 人なら根のサービスを握って観測し、読み直す。
  func beginWatching() {
    watchers += 1
    guard watchers == 1 else { return reload() }
    let files = RootFiles.shared(for: root)
    self.files = files
    files.addObserver(self)
    SourceControl.shared(for: root).addObserver(self)
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
    state?.endWatching()
  }

  /// 読み直す。PR があれば、その中身も読み直す。
  func reload() {
    guard watchers > 0, let files else { return }
    guard files.isResolved else { return }
    guard let repo = files.repo else { return settle(.unavailable(.notGit)) }
    guard let status = files.status else { return }
    guard let name = status.branch?.name else { return settle(.unavailable(.detached)) }
    head = status.branch?.commit
    if isReading {
      readAgain = true
      return
    }
    if name != branch {
      branch = name
      settle(.reading)
    }
    isReading = true
    repo.defaultBranch { [weak self] remoteDefault in
      self?.lookUp(name, in: repo, remoteDefault: remoteDefault)
    }
  }

  private func lookUp(_ name: String, in repo: GitRepo, remoteDefault: String) {
    let defaultBranch = GitBranch.localName(fromRemote: remoteDefault)
    guard name != defaultBranch else { return finish(.unavailable(.defaultBranch), name) }
    source.branchPullRequests(repo, name) { [weak self] found in
      guard let self else { return }
      switch found.branches[name] {
      case nil: finish(.unavailable(.failed(.reason(""))), name)
      case .unavailable(let reason)?: finish(.unavailable(Self.unavailable(reason)), name)
      case .gitHub(_, .failure(let reason))?: finish(.unavailable(.failed(reason)), name)
      case .gitHub(let ref, .success(let pullRequests))?:
        let open = pullRequests.first { $0.state == "OPEN" }
        if let id = open?.url.flatMap(GitHubItemID.init(pullRequestURL:)) {
          let state = PullRequestState.shared(
            for: PullRequestState.Key(commonDir: repo.commonDir, id: id), source: source)
          state.attach(repo: repo, fetchRemote: Self.remote(of: id.repo, in: found.ledger))
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
    let tracking = remoteDefault.contains("/") ? "refs/remotes/" + remoteDefault : nil
    let count: (@escaping (Int?) -> Void) -> Void = { done in
      guard let tracking else { return done(nil) }
      repo.counts("HEAD", against: tracking) { done($0?.ahead) }
    }
    count { [weak self] ahead in
      guard let self else { return }
      let creation = Creation(
        branch: name, defaultBranch: defaultBranch, ahead: ahead,
        url: ref.pullRequestCreationURL, ref: ref, published: .checking)
      finish(.noPullRequest(creation), name)
      source.branchExists(ref) { [weak self] exists in
        guard let self, case .noPullRequest(var current) = answer, current.ref == ref else {
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

  /// 読み終えた。読んでいる間にブランチが変わっていれば答えを捨て（前のブランチの答えは出さない）、変わっていたか、
  /// きっかけが来ていれば読み直す。
  private func finish(_ next: Answer, _ name: String) {
    isReading = false
    let current = files?.status?.branch?.name
    if name == current { settle(next) }
    recordTracking()
    if readAgain || name != current {
      readAgain = false
      reload()
    }
  }

  /// 答えを `next` にする。PR が替われば、前の PR を見るのをやめ、今の PR を見て中身を読み直す。
  private func settle(_ next: Answer) {
    let previous = state
    if answer != next { answer = next }
    let current = state
    if previous !== current {
      previous?.removeObserver(self)
      previous?.endWatching()
      current?.addObserver(self)
      current?.beginWatching()
      counted = nil
    }
    current?.reload()
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

  /// 手元の HEAD と PR の先頭の間で、手元とのずれを数える（両端が揃った後。数えた組と同じなら数え直さない）。両端を
  /// 取れなかったときは数えず、手元の HEAD が PR の先頭と違うかだけを見る。
  private func countDrift() {
    guard let state, let content = state.content else {
      drift = nil
      return
    }
    let local = head
    switch state.bounds {
    case .none, .fetching:
      drift = nil
    case .failed:
      drift = local == content.headCommit ? .inSync : .differs
    case .ready(_, let ends):
      if let counted, counted.local == local, counted.pullRequest == ends.head { return }
      counted = (local, ends.head)
      guard let local, let repo = files?.repo else {
        drift = .differs
        return
      }
      repo.counts(local, against: ends.head) { [weak self] counts in
        guard let self, self.counted?.local == local, self.counted?.pullRequest == ends.head else {
          return
        }
        drift =
          counts.map {
            $0.ahead == 0 && $0.behind == 0
              ? .inSync : .diverged(ahead: $0.ahead, behind: $0.behind)
          }
          ?? .differs
      }
    }
  }

  // MARK: - 追跡 ref

  /// このブランチの push 先の追跡 ref と、PR のベースブランチの追跡 ref の今の値。
  private func readTracking(_ completion: @escaping ([String: String]?) -> Void) {
    guard let repo = files?.repo, let branch else { return completion(nil) }
    repo.pushTracking(ofBranch: branch) { [weak self] push in
      guard let self else { return }
      var refs: [String] = []
      if case .ref(let ref, _)? = push { refs.append(ref) }
      if let remote = state?.fetchRemote, let base = state?.content?.baseRefName {
        refs.append("refs/remotes/\(remote)/\(base)")
      }
      repo.refValues(refs, completion: completion)
    }
  }

  /// 読み終えた時点の追跡 ref の値を覚える（次にリモート追跡の ref が動いたとき、比べる相手）。
  private func recordTracking() {
    readTracking { [weak self] values in self?.tracked = values }
  }
}

/// 根のサービスの知らせ——管理下かの判定・status（ブランチ名と HEAD）・リモート追跡の ref の変化。
extension BranchPullRequest: RootFilesObserver {
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {}

  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {}

  func rootFilesDidResolve(_ files: RootFiles) {
    reload()
  }

  /// ブランチ名が変われば引き直す。HEAD だけが動いたなら、手元とのずれを数え直す。
  func rootFilesStatusDidChange(_ files: RootFiles) {
    let name = files.status?.branch?.name
    if name != branch { return reload() }
    head = files.status?.branch?.commit
    countDrift()
  }

  /// リモート追跡の ref が動いたかもしれない——このブランチの push 先か PR のベースブランチの追跡 ref の値が変わって
  /// いたときだけ読み直す（無関係なブランチが fetch で動くたびに GitHub へ問い合わせない）。
  func rootFilesGitStateDidChange(_ files: RootFiles, remoteRefsChanged: Bool) {
    guard remoteRefsChanged, !isReading, let previous = tracked else { return }
    readTracking { [weak self] values in
      guard let self, let values, values != previous else { return }
      tracked = values
      reload()
    }
  }
}

/// Orbe の中のネット操作（プッシュ・プル・フェッチ・同期・公開・コミットしてプッシュ）が終わったら読み直す。
extension BranchPullRequest: SourceControlObserver {
  func sourceControl(
    _ control: SourceControl, firstStepDidFinish operation: SourceControl.Operation,
    outcome: SourceControl.FirstStepOutcome
  ) {}

  func sourceControl(_ control: SourceControl, operationDidFinish kind: SourceControl.Kind) {
    guard kind.isNetwork else { return }
    reload()
  }
}

/// PR の中身・両端が変わったら、手元とのずれを数え直す。
extension BranchPullRequest: PullRequestStateObserver {
  func pullRequestStateDidChange(_ state: PullRequestState) {
    countDrift()
  }
}
