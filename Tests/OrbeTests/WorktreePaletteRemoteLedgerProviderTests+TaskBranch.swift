import XCTest

@testable import Orbe

/// タスクから開いた ⌘T の先頭の欄が、主の Issue・PR のブランチを手元で見つけるまでの待ちと、PR の head と同じ
/// 名前のローカルブランチの扱い。ブランチが手元に無い間は提示時の fetch の着地まで、PR の head と同名の
/// ローカルブランチは同一性（push 先の remote の正式名＋名前）が分かるまで欄を決めず、↵ を預かる。
///
/// 壊れると何が起きるか: 同僚の新しい PR のタスクから ⌘T を開いてすぐ ↵ を押すと、fetch が着地する前に欄なしで
/// 決まり、今の worktree（main のこともある）がタスクに付いて進行中になる。Issue では push 済みの
/// issue/<N> と分岐した同名のブランチを切る。fork の main から出た PR のタスクで、自分の main の worktree が
/// 「#N の worktree」として選ばれる。gh の無い環境で ↵ が預かられたまま、パレットを閉じられなくなる。
extension WorktreePaletteRemoteLedgerProviderTests {
  /// `repository`（owner/name）の github.com の origin（`ssh://git@github.com/<repository>.git`）を、ローカルの
  /// bare リポジトリで立てる。ssh は起こさない: リポジトリの `core.sshCommand` を、git が渡す upload-pack の
  /// コマンドを bare リポジトリに向けて走らせるスクリプトにする（`ssh.variant=simple` で ssh の選択肢を付けさせ
  /// ない）。台帳は insteadOf を展開した後の URL を読むので、insteadOf ではローカルへ向けられない。main を置き、
  /// `branches` を main から切る。
  private func serveOrigin(_ repository: String, branches: [String] = []) throws {
    let bare = dir.appendingPathComponent("origin.git").path
    XCTAssertTrue(run(["init", "-q", "--bare", "-b", "main", bare], in: dir.path).isSuccess)
    XCTAssertTrue(git(["push", "-q", bare, "main"]).isSuccess)
    for branch in branches {
      XCTAssertTrue(run(["branch", branch, "main"], in: bare).isSuccess)
    }
    let ssh = dir.appendingPathComponent("local-ssh").path
    try write(
      """
      #!/bin/sh
      echo "$@" >> "\(sshLog)"
      for last; do :; done
      exec sh -c "$(printf '%s' "$last" | sed "s#'/\(repository).git'#'\(bare)'#")"
      """, to: ssh)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh)
    XCTAssertTrue(
      git(["remote", "add", "origin", "ssh://git@github.com/\(repository).git"]).isSuccess)
    XCTAssertTrue(git(["config", "core.sshCommand", ssh]).isSuccess)
    XCTAssertTrue(git(["config", "ssh.variant", "simple"]).isSuccess)
  }

  /// `serveOrigin` の ssh の代役が受けた呼び出し。fetch がネットワークに出ず代役を通ったことを確かめる。
  private var sshLog: String { dir.appendingPathComponent("local-ssh.log").path }

  private func fetchWentThroughTheLocalOrigin() -> Bool {
    (try? String(contentsOfFile: sshLog, encoding: .utf8))?.contains("github.com") == true
  }

  /// 提示時の fetch を `releaseFetch()` まで着地させない（origin の upload-pack を門で止める）。
  private func holdFetch() throws {
    let gate = dir.appendingPathComponent("fetch-gate").path
    let wrapper = dir.appendingPathComponent("held-upload-pack").path
    try FileManager.default.createDirectory(atPath: gate, withIntermediateDirectories: true)
    try write(
      "#!/bin/sh\nwhile [ -d \"\(gate)\" ]; do sleep 0.05; done\nexec git-upload-pack \"$@\"\n",
      to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
    XCTAssertTrue(git(["config", "remote.origin.uploadpack", wrapper]).isSuccess)
  }

  private func releaseFetch() throws {
    try FileManager.default.removeItem(at: dir.appendingPathComponent("fetch-gate"))
  }

  /// 主の PR の値（head）が既に届いている置き場。
  private func items(_ pr: TaskLink, head: GitHubBranchRef) -> GitHubItemCache {
    GitHubItemCache(
      answers: [
        pr.item: .found(
          GitHubItemSummary(
            title: "pr", state: .open,
            pullRequest: .init(isDraft: false, review: nil, checks: nil, author: "me", head: head)))
      ], fetch: { _, _ in })
  }

  /// 開いて、git の一覧が届くまで待つ。`executed` に ↵ の行き先を溜める。
  private func open(
    _ task: TaskItem, items: GitHubItemCache = GitHubItemCache(fetch: { _, _ in }),
    executed: @escaping (WorktreePaletteDestination) -> Void
  ) -> (WorktreePaletteModel, WorktreePaletteDataProvider) {
    let (model, provider) = makeTaskProvider(task, items: items)
    model.onExecute = executed
    provider.load()
    XCTAssertTrue(pump { model.hasLoadedOnce && model.newBranchRules != nil }, "前提: 一覧が届く")
    return (model, provider)
  }

  // MARK: - 手元に無いブランチは fetch の着地まで待つ

  func testAPullRequestBranchOnlyOnTheServerWaitsForTheFetchThenActsOnIt() throws {
    try serveOrigin("me/r", branches: ["feat"])
    try answer("me/r", found: "me/r")
    try holdFetch()
    let pr = link(.pr, "me/r", 230)
    var executed: [WorktreePaletteDestination] = []
    let (model, provider) = open(
      task { $0.links = [pr] }, items: items(pr, head: GitHubBranchRef(repo: mine, branch: "feat"))
    ) { executed.append($0) }

    XCTAssertFalse(provider.facts.remoteFetchLanded, "前提: fetch はまだ着地していない")
    XCTAssertTrue(model.taskTargetPending, "手元に無いブランチは fetch の着地まで決めない")
    model.activate()
    XCTAssertEqual(executed, [], "↵ は預かる")

    try releaseFetch()

    XCTAssertTrue(pump { !executed.isEmpty })
    XCTAssertTrue(fetchWentThroughTheLocalOrigin(), "前提: fetch はローカルの origin で済んだ")
    XCTAssertEqual(
      executed, [.remoteBranch(name: "origin/feat", existingWorktree: nil)], "届いたブランチで効く")
  }

  /// 着地しても見つからなければ欄なしで決まり、預かった ↵ はいつもの ⌘T と同じく今の worktree に効く。
  func testAPullRequestBranchMissingEvenAfterTheFetchSettlesWithoutASection() throws {
    try serveOrigin("me/r")
    try answer("me/r", found: "me/r")
    try holdFetch()
    let pr = link(.pr, "me/r", 230)
    var executed: [WorktreePaletteDestination] = []
    let (model, provider) = open(
      task { $0.links = [pr] }, items: items(pr, head: GitHubBranchRef(repo: mine, branch: "gone"))
    ) { executed.append($0) }
    model.activate()
    XCTAssertEqual(executed, [], "前提: ↵ は預かる")

    try releaseFetch()

    XCTAssertTrue(pump { !executed.isEmpty })
    XCTAssertTrue(fetchWentThroughTheLocalOrigin(), "前提: fetch はローカルの origin で済んだ")
    XCTAssertNil(taskSection(model), "欄を出さない")
    XCTAssertEqual(executed, [.directory(path: root)], "今の worktree に効く")
    withExtendedLifetime(provider) {}
  }

  func testAnIssueBranchOnlyOnTheServerWaitsForTheFetchThenActsOnIt() throws {
    try serveOrigin("me/r", branches: ["issue/221"])
    try answer("me/r", found: "me/r")
    try holdFetch()
    var executed: [WorktreePaletteDestination] = []
    let (model, provider) = open(task { $0.links = [link(.issue, "me/r", 221)] }) {
      executed.append($0)
    }
    XCTAssertTrue(model.taskTargetPending, "手元に無いブランチは fetch の着地まで決めない")
    model.activate()
    XCTAssertEqual(executed, [], "作成行で決めず、↵ は預かる")

    try releaseFetch()

    XCTAssertTrue(pump { !executed.isEmpty })
    XCTAssertTrue(fetchWentThroughTheLocalOrigin(), "前提: fetch はローカルの origin で済んだ")
    XCTAssertEqual(
      executed, [.remoteBranch(name: "origin/issue/221", existingWorktree: nil)],
      "push 済みのブランチで効く（同名のブランチを新しく切らない）")
    withExtendedLifetime(provider) {}
  }

  // MARK: - PR の head と同じ名前のローカルブランチ

  /// fork（別の remote）の main から出た PR は、自分の main（push 先は origin）とは別のブランチ。欄は出さない。
  func testALocalBranchNamedLikeAForksHeadIsNotTheTasksBranch() throws {
    addRemote("origin", "me/r")
    addRemote("alice", "alice/r")
    try answer("me/r", found: "me/r")
    try answer("alice/r", found: "alice/r")
    let pr = link(.pr, "alice/r", 9)
    let head = GitHubBranchRef(repo: GitHubRepoName(nameWithOwner: "alice/r"), branch: "main")
    let (model, provider) = makeTaskProvider(task { $0.links = [pr] }, items: items(pr, head: head))

    provider.load()
    XCTAssertTrue(settle(model))

    XCTAssertNil(taskSection(model), "自分の main を #9 の worktree として出さない")
    XCTAssertEqual(model.selectedItem?.isCurrent, true)
  }

  /// 同一性は gh の確認と remote の正式名が要る。届くまでは決めず ↵ を預かり、届いたら head と同じブランチの
  /// 行で効く。
  func testALocalHeadBranchWaitsForTheCanonicalNameThenActsOnIt() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    try gate("resolve")
    XCTAssertTrue(git(["branch", "docs/readme-en"]).isSuccess)
    let pr = link(.pr, "me/r", 230)
    var executed: [WorktreePaletteDestination] = []
    let (model, provider) = open(
      task { $0.links = [pr] },
      items: items(pr, head: GitHubBranchRef(repo: mine, branch: "docs/readme-en"))
    ) { executed.append($0) }
    XCTAssertTrue(pump { calls("R").contains("me/r") }, "前提: 正式名を問い合わせている")
    XCTAssertTrue(model.taskTargetPending, "正式名が届くまで決めない")
    model.activate()
    XCTAssertEqual(executed, [], "↵ は預かる")

    try ungate("resolve")

    XCTAssertTrue(pump { !executed.isEmpty })
    XCTAssertEqual(executed, [.localBranch(name: "docs/readme-en")])
    withExtendedLifetime(provider) {}
  }

  /// gh が使えなければ同一性を確かめられないので、PR の head と同名のローカルブランチは使わず欄なしで決まる
  /// （PR の自動の結び付けと同じ側）。Issue の issue/<N> は名前で決まるので、gh が無くても使う。
  func testWithoutGhAPullRequestSettlesWithoutASectionButAnIssueUsesItsBranchByName() throws {
    addRemote("origin", "me/r")
    ShellPATH.shared = ShellPATH(probe: { "/usr/bin:/bin" })
    XCTAssertTrue(git(["branch", "docs/readme-en"]).isSuccess)
    XCTAssertTrue(git(["branch", "issue/221"]).isSuccess)
    let pr = link(.pr, "me/r", 230)
    let (prModel, prProvider) = makeTaskProvider(
      task { $0.links = [pr] },
      items: items(pr, head: GitHubBranchRef(repo: mine, branch: "docs/readme-en")))
    let (issueModel, issueProvider) = makeTaskProvider(
      task { $0.links = [link(.issue, "me/r", 221)] })

    prProvider.load()
    issueProvider.load()
    XCTAssertTrue(settle(prModel))
    XCTAssertTrue(settle(issueModel))

    XCTAssertNil(taskSection(prModel), "PR: 欄なしで決まる")
    XCTAssertEqual(
      taskSection(issueModel)?.items.map(\.action), [.open(.localBranch(name: "issue/221"))],
      "Issue: 名前で決まる")
  }

  // MARK: - 正式名

  /// origin の URL が改名前の名前でも、正式名で本体のリポジトリと分かれば欄が出る。正式名が届くまでは ↵ を
  /// 預かり、届いたら欄の行で効く。
  func testAnIssueMatchedOnlyByTheCanonicalNameWaitsForItThenActs() throws {
    addRemote("origin", "me/old-name")
    try answer("me/old-name", found: "me/r")
    try gate("resolve")
    var executed: [WorktreePaletteDestination] = []
    let (model, provider) = open(task { $0.links = [link(.issue, "me/r", 221)] }) {
      executed.append($0)
    }
    XCTAssertTrue(pump { calls("R").contains("me/old-name") }, "前提: 正式名を問い合わせている")
    XCTAssertTrue(model.taskTargetPending, "正式名が届くまで決めない")
    model.activate()
    XCTAssertEqual(executed, [], "↵ は預かる")

    try ungate("resolve")

    XCTAssertTrue(pump { !model.taskTargetPending })
    XCTAssertEqual(taskSection(model)?.items.map(\.action), [.createBranch(name: "issue/221")])
    XCTAssertTrue(pump { !model.hasPendingActivation }, "預かった ↵ は欄の行で解ける")
    withExtendedLifetime(provider) {}
  }
}
