import XCTest

@testable import Orbe

/// remote の台帳を provider の中で育てる経路（正式名の問い合わせ・キャッシュ・着地後の描き直し）と、
/// clean の PR の事実をその台帳で絞る経路。実 git の一時リポジトリと偽の `gh` で、本物の着地経路を通す。
///
/// 壊れると、次のどれかが黙って起きる。
/// - 問い合わせが揃う前に撃たれて失敗し、PR がローディングのまま、チップも出ないまま固まる。
/// - 同じ名前を何度も問い合わせる。
/// - 確かめられない答えが焼かれ、開き直しても直らない。
/// - clean が他人の fork の PR で行を塞ぐ、または自分の PR（base を追跡する行・fork の運用）を
///   見落として、レビュー中の worktree を安全群に入れる。
@MainActor
final class DispatchRemoteLedgerProviderTests: OrbeTestCase {
  var dir: URL!
  var root: String!
  var ghDir: URL!

  let mine = GitHubRepoName(nameWithOwner: "me/r")

  override func setUpWithError() throws {
    let created = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-ledger-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
    dir = URL(fileURLWithPath: String(cString: realpath(created.path, nil)))
    root = dir.appendingPathComponent("repo").path
    XCTAssertTrue(run(["init", "-q", "-b", "main", root], in: dir.path).isSuccess)
    XCTAssertTrue(git(["config", "user.email", "t@example.com"]).isSuccess)
    XCTAssertTrue(git(["config", "user.name", "t"]).isSuccess)
    // origin を github.com の URL にしても、提示時の fetch がネットへ出ないようにする（即失敗する）。
    XCTAssertTrue(git(["config", "protocol.https.allow", "never"]).isSuccess)
    try "x".write(
      toFile: (root as NSString).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "init"]).isSuccess)
    try stageGh()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  // MARK: - 正式名の問い合わせ

  /// 正式名が分かるまでは PR 行の行き先もチップも決まらないのでローディング行だけ。答えが着地したら
  /// PR 行とチップが出る。origin の URL が改名前の名前でも、正式名で PR の head と同じと分かる。
  func testPullRequestsWaitForTheCanonicalNameThenLinkRows() throws {
    addRemote("origin", "me/old-name")
    try answer("me/old-name", found: "me/r")
    try servePullRequest(1, head: "feat", from: "me/r")
    let worktree = try addWorktree("wt-feat", branch: "feat")
    try gate("resolve")
    // ブランチの PR の着地による描き直しに頼らず、答えの着地そのもので描き直すことを見る。
    try gate("branch")
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(
      pump({
        self.calls("R").contains("me/old-name") && provider.pullRequests.count == 1
          && !provider.pullRequestsFetching && !provider.issuesFetching
          && model.classification != nil && provider.probingPaths.isEmpty
      }), "前提: 一覧と分類は着地し、正式名の問い合わせだけが着地していない")
    XCTAssertEqual(
      section(model, "Pull requests")?.items.map(\.isLoadingRow), [true], "PR 行を出さずローディング行だけ")
    XCTAssertNil(item(model, "wt-feat")?.linkedPRNumber, "チップを出さない")
    XCTAssertEqual(provider.branchPRStates["feat"], .fetching, "clean の PR の事実はまだ分からない")

    try ungate("resolve")
    // ブランチの PR の問い合わせが打ち切り（15 秒）で着地して描き直すより前に出ること。
    XCTAssertTrue(pump({ self.pullRequestRow(model, 1) != nil }, timeout: 5), "答えの着地で PR 行が出る")
    XCTAssertEqual(item(model, "wt-feat")?.linkedPRNumber, 1)
    XCTAssertEqual(
      pullRequestRow(model, 1)?.action,
      .pullRequest(number: 1, route: .open(.worktree(path: worktree))))
  }

  /// 撃つのは remote の一覧と認証確認の両方が揃ってから。GitHub の remote ごとに 1 回だけで、着地前に
  /// git の一覧が引き直されても二重に撃たない。GitHub でない remote は問い合わせない。
  func testLookupFiresOnceEachGitHubRemoteAfterBothLanesLand() throws {
    addRemote("origin", "me/r")
    addRemote("upstream", "base/r")
    XCTAssertTrue(git(["remote", "add", "mirror", "/srv/mirror.git"]).isSuccess)
    try answer("me/r", found: "me/r")
    try answer("base/r", found: "base/r")
    try gate("auth")
    try gate("resolve")
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(pump({ provider.remoteListing != nil && model.classification != nil }))
    XCTAssertFalse(pump({ !self.calls("R").isEmpty }, timeout: 1), "認証確認が着地するまで撃たない")

    try ungate("auth")
    XCTAssertTrue(pump({ self.calls("R").count == 2 }), "認証確認の着地で撃つ")
    var relanded = false
    provider.loadGit(try XCTUnwrap(provider.repo), classifying: false) { relanded = true }
    XCTAssertTrue(pump({ relanded }), "前提: 問い合わせ中に git の一覧が引き直された")

    try ungate("resolve")
    XCTAssertTrue(pump({ provider.remoteLedger != .pending }))
    XCTAssertEqual(calls("R").sorted(), ["base/r", "me/r"])
  }

  /// 問い合わせが失敗したら origin は「確かめられない」になり（PR は情報行とブラウザで開く行・チップ無し・
  /// clean は取得失敗）、その回は問い合わせ直さない。開き直せば裏で問い直して直る。
  func testUnverifiedLookupIsAskedAgainOnReopen() throws {
    addRemote("origin", "me/r")
    try servePullRequest(1, head: "feat", from: "me/r")
    let worktree = try addWorktree("wt-feat", branch: "feat")
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(pump({ self.originUnverified(provider) && provider.pullRequests.count == 1 }))
    XCTAssertEqual(
      section(model, "Pull requests")?.items.map(\.infoKind), [.repositoryUnverified, nil],
      "ローディング行を残さず、情報行と PR 行を出す")
    XCTAssertEqual(pullRequestRow(model, 1)?.action, .pullRequest(number: 1, route: .browser))
    XCTAssertNil(item(model, "wt-feat")?.linkedPRNumber)
    XCTAssertEqual(provider.branchPRStates["feat"], .failed, "安全群に入らない側に倒れる")
    var relanded = false
    provider.loadGit(try XCTUnwrap(provider.repo), classifying: false) { relanded = true }
    XCTAssertTrue(pump({ relanded }))
    XCTAssertEqual(calls("R"), ["me/r"], "同じ回では問い合わせ直さない")

    try answer("me/r", found: "me/r")
    let (reopened, again) = makeProvider()
    again.load()
    XCTAssertTrue(
      pump({
        self.pullRequestRow(reopened, 1)?.action
          == .pullRequest(number: 1, route: .open(.worktree(path: worktree)))
      }), "開き直すと直る")
    XCTAssertEqual(calls("R"), ["me/r", "me/r"], "確かめられない答えは開き直すと問い直す")
  }

  /// 答え（正式名・確かめられない）はプロセス内に残るので、2 回目に開いたときは gh を待たずに最初の描画
  /// から PR 行とチップが出る。問い直すのは確かめられない答えだけ。
  func testSecondOpenShowsPullRequestsFromTheFirstFrameWithoutAskingAgain() throws {
    addRemote("origin", "me/r")
    addRemote("upstream", "base/r")
    try answer("me/r", found: "me/r")
    try answerNotFound("base/r")
    try servePullRequest(1, head: "feat", from: "me/r")
    _ = try addWorktree("wt-feat", branch: "feat")
    let (first, provider) = makeProvider()
    provider.load()
    XCTAssertTrue(pump({ self.pullRequestRow(first, 1) != nil }), "前提: 1 回目で答えが揃う")

    try gate("auth")
    let (model, again) = makeProvider()
    again.load()
    XCTAssertTrue(pump({ model.hasLoadedOnce }))
    XCTAssertNotNil(pullRequestRow(model, 1), "認証確認より前の描画から PR 行が出る")
    XCTAssertEqual(item(model, "wt-feat")?.linkedPRNumber, 1)

    try ungate("auth")
    XCTAssertTrue(pump({ again.githubReady && !again.pullRequestsFetching }))
    XCTAssertTrue(pump({ self.calls("R").count == 3 }))
    XCTAssertEqual(calls("R").sorted(), ["base/r", "base/r", "me/r"], "正式名の答えは問い合わせ直さない")
  }

  // MARK: - clean の PR の事実

  /// clean の PR は worktree のローカル名で問い合わせ、head がその worktree の ref と等しいものだけを
  /// 事実にする。base（`origin/main`）を追跡する行でも自分の PR が残り、他人の fork の同名ブランチの
  /// レビュー中 PR は行を塞がない。
  func testCleanPullRequestFactsFollowTheLocalBranchAndDropOtherForks() throws {
    addRemote("origin", "me/r")
    addRemote("upstream", "base/r")
    try answer("me/r", found: "me/r")
    try answer("base/r", found: "base/r")
    XCTAssertTrue(git(["update-ref", "refs/remotes/origin/main", "HEAD"]).isSuccess)
    let worktree = try addWorktree("wt-feat", branch: "feat")
    XCTAssertTrue(run(["branch", "-q", "--set-upstream-to=origin/main"], in: worktree).isSuccess)
    try serveBranchPullRequests(
      "feat",
      #"[{"number":6,"headRefName":"feat","state":"OPEN","baseRefName":"main","#
        + #""headRepositoryOwner":{"login":"x"},"headRepository":{"name":"r"}},"#
        + #"{"number":5,"headRefName":"feat","state":"MERGED","baseRefName":"develop","#
        + #""headRepositoryOwner":{"login":"me"},"headRepository":{"name":"r"}}]"#)
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(
      pump({
        guard case .loaded = provider.branchPRStates["feat"] else { return false }
        return model.classification != nil
      }))

    XCTAssertEqual(calls("H"), ["feat"], "追跡先の main ではなくローカル名 feat で問う")
    XCTAssertEqual(
      provider.branchPRStates["feat"],
      .loaded([
        GitHubBranchPR(
          number: 5, headRefName: "feat", state: "MERGED", baseRefName: "develop",
          headRepository: mine)
      ]))
    let row = try XCTUnwrap(model.classification?.first { $0.branch == "feat" })
    XCTAssertTrue(row.vocabulary.contains(.mergedPR(5, base: "develop")), "自分の merged PR は事実になる")
    XCTAssertFalse(row.vocabulary.contains(.openPR(6)), "他人の fork のレビュー中 PR は事実にしない")
  }

  /// GitHub でない remote へ push する worktree は、PR の事実を「確かめて 0 件」として問い合わせない。
  func testWorktreeTrackingANonGitHubRemoteHasNoPullRequestsToAsk() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    XCTAssertTrue(git(["remote", "add", "mirror", "/srv/mirror.git"]).isSuccess)
    XCTAssertTrue(git(["update-ref", "refs/remotes/mirror/side", "HEAD"]).isSuccess)
    let worktree = try addWorktree("wt-side", branch: "side")
    XCTAssertTrue(run(["branch", "-q", "--set-upstream-to=mirror/side"], in: worktree).isSuccess)
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(pump({ provider.remoteLedger != .pending && model.classification != nil }))
    XCTAssertEqual(provider.branchPRStates["side"], .loaded([]))
    XCTAssertEqual(calls("H"), [])
  }

  /// origin が GitHub でないリポジトリは gh を使わないので、GitHub の remote が別にあって台帳が確定
  /// しなくても、clean はそれを待たない（確認対象が無いので git の事実だけで判定する）。
  func testNonGitHubRepositoryDoesNotWaitForTheLedger() throws {
    XCTAssertTrue(git(["remote", "add", "origin", "/srv/origin.git"]).isSuccess)
    addRemote("upstream", "base/r")
    _ = try addWorktree("wt-feat", branch: "feat")
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(pump({ model.classification != nil && !provider.classificationPending }))
    XCTAssertEqual(provider.remoteLedger, .pending, "前提: GitHub の remote の正式名は問い合わせない")
    XCTAssertEqual(provider.branchPRStates["feat"], .loaded([]))
  }
}
