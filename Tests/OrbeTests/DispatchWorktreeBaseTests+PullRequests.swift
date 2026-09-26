import XCTest

@testable import Orbe

/// fetch の着地前に Enter された PR 行が、着地を待ってから着地後の行き先で worktree を作ること。
///
/// 壊れると、前回の fetch の後に立った PR（他のマシン・Web・クラウドエージェントが立てたもの）を
/// パレットを開いてすぐ Enter した人だけ、worktree が作られずブラウザが開く。待ちの終わりが組み直しより
/// 先に来ても同じことが起きる（着地前の行を読んで決めてしまう）。
extension DispatchWorktreeBaseTests {

  /// 着地前は「作成中…」のまま待ち、着地後に fetch で届いた `origin/<head>` を追跡する worktree を作る。
  func testPullRequestEnteredBeforeTheFetchLandsIsCutFromTheFetchedHead() throws {
    try serveFreshPullRequest()
    let provider = try startWithSlowFetch(holdingFetch: true, gitHub: GitHubCLI())
    let row = { self.palette.items.firstIndex { $0.idText == "#9" } }
    let awaiting = DispatchAction.pullRequest(number: 9, route: .awaitingFetch)
    XCTAssertTrue(
      pump({ row().map { self.palette.items[$0].action } == awaiting }), "前提: 着地前の PR 行は着地を待つ行")
    // WindowController と同じ配線。
    palette.onAwaitRemoteFetch = { provider.remoteFetchLanding.notify(queue: .main, execute: $0) }
    var executed: [DispatchDestination] = []
    var outcome: DispatchDataProvider.DispatchPrepareOutcome?
    palette.onExecute = { destination in
      executed.append(destination)
      provider.prepareDirectory(for: destination) { outcome = $0 }
    }

    palette.activate(at: try XCTUnwrap(row()))
    XCTAssertTrue(palette.isPreparing, "作成中のまま待つ")
    XCTAssertTrue(executed.isEmpty, "着地前には作らない")
    releaseFetch()

    XCTAssertTrue(pump({ outcome != nil }, timeout: 30), "着地後に作成へ進む")
    XCTAssertEqual(executed, [.remoteBranch(name: "origin/fresh", existingWorktree: nil)])
    guard case .resolved(.ready(let path))? = outcome else {
      return XCTFail("worktree ができない: \(String(describing: outcome))")
    }
    XCTAssertEqual(head(of: path), originTip("fresh"), "fetch で届いた origin/fresh が base")
    XCTAssertEqual(oid(["config", "--get", "branch.fresh.merge"], cwd: local), "refs/heads/fresh")
  }

  /// 手元が最後に fetch した後に origin へ `fresh` を push し、その PR を立てる。origin は github.com の
  /// パスに見せ（パスの最後の 2 段で `me/r` と読まれる）、偽 `gh` がその PR と正式名を返す。
  private func serveFreshPullRequest() throws {
    let other = dir.appendingPathComponent("other").path
    XCTAssertTrue(run(["checkout", "-q", "-b", "fresh", "main"], cwd: other).isSuccess)
    try commit("fresh-1", in: other)
    XCTAssertTrue(run(["push", "-q", "origin", "fresh"], cwd: other).isSuccess)

    let owner = dir.appendingPathComponent("github.com/me")
    try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
    let link = owner.appendingPathComponent("r.git").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: origin)
    XCTAssertTrue(run(["remote", "set-url", "origin", link], cwd: local).isSuccess)

    let bin = dir.appendingPathComponent("gh-bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let node =
      #"{"number":9,"title":"fresh","headRefName":"fresh","#
      + #""headRepositoryOwner":{"login":"me"},"headRepository":{"name":"r"},"reviewDecision":null}"#
    let script = """
      #!/bin/sh
      if [ "$1" = "auth" ]; then echo token; exit 0; fi
      if [ "$1" = "pr" ]; then printf '[]'; exit 0; fi
      case "$*" in
        *'repository(owner:$o,'*) printf '{"data":{"repository":{"nameWithOwner":"me/r"}}}' ;;
        *pullRequests*) printf '%s' '{"nodes":[\(node)],"pageInfo":{"hasNextPage":false,"endCursor":null}}' ;;
        *) printf '{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}' ;;
      esac
      """
    let gh = bin.appendingPathComponent("gh").path
    try script.write(toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
    // 戻さない——`OrbeTestCase` が毎テスト `ShellPATH.shared` を張り直す。
    let path = bin.path
    ShellPATH.shared = ShellPATH(probe: { "\(path):/usr/bin:/bin" })
  }
}
