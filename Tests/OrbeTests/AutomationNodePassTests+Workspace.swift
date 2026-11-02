import XCTest

@testable import Orbe

/// workspace で走るコマンド——回の始めに、走る workspace をその時点の root に解き、root からの相対の作業ディレクトリで起こす。
/// 解けなければ（消した workspace）手段を起こさずに失敗し、結果は呼び出しの後の main の巡りで 1 度だけ返る。
///
/// 壊れると何が起きるか: root を変えた workspace の古い場所で走り続ける。消した workspace のコマンドがホームで走る。起こさずに
/// 失敗した結果が `start` の中で返り、走らせ役が手を置く前に確定・下流の起こしが入れ子に走る。止めた回の結果が後から返る。
extension AutomationNodePassTests {
  private static let repo = UUID()

  private func workspace(root: String) -> AutomationWorkspaces {
    AutomationWorkspaces(
      all: [AutomationWorkspace(id: Self.repo, name: "orbe", root: root)],
      home: nil)
  }

  private func command(directory: String?) -> AutomationDefinition.Node {
    DesignSceneFixtures.commandNode(
      "f", "f", .manual, script: "pwd", workspace: Self.repo, directory: directory,
      coverage: .currentSet)
  }

  private func directory(_ index: Int) -> String? {
    guard case .command(let command, _) = jobs.calls[index].job.work else { return nil }
    return command.directory
  }

  private func nextTurn() {
    let turned = expectation(description: "main の次の巡り")
    DispatchQueue.main.async { turned.fulfill() }
    wait(for: [turned], timeout: 1)
  }

  func testACommandRunsUnderTheWorkspaceRootOfTheMoment() {
    workspaces = workspace(root: "/src/orbe")
    start(command(directory: "."), .fetch, .fetch(since: nil, reachesJudge: false))
    start(command(directory: "tools/../sub"), .fetch, .fetch(since: nil, reachesJudge: false))
    workspaces = workspace(root: "/moved/orbe")
    start(command(directory: "sub"), .fetch, .fetch(since: nil, reachesJudge: false))
    start(
      DesignSceneFixtures.commandNode(
        "f", "f", .manual, script: "pwd", directory: "/opt/x", coverage: .currentSet),
      .fetch, .fetch(since: nil, reachesJudge: false))

    XCTAssertEqual(
      jobs.calls.indices.map(directory),
      ["/src/orbe", "/src/orbe/sub", "/moved/orbe/sub", "/opt/x"],
      "root の変更は次の回から効く。workspace の無いコマンドは書いたまま")
  }

  /// 自動化から継いだ workspace（検証が導いた値）でも同じに解く。
  func testAnInheritedWorkspaceResolvesTheSame() {
    workspaces = workspace(root: "/src/orbe")
    start(
      DesignSceneFixtures.commandNode(
        "f", "f", .manual, script: "pwd", directory: "sub", coverage: .currentSet),
      .fetch, .fetch(since: nil, reachesJudge: false), workspace: Self.repo)

    XCTAssertEqual(directory(0), "/src/orbe/sub")
  }

  func testACommandWhoseWorkspaceIsGoneFailsOnTheNextTurnWithoutStarting() {
    start(command(directory: "."), .fetch, .fetch(since: nil, reachesJudge: false))

    XCTAssertTrue(jobs.calls.isEmpty, "手段を起こさない")
    XCTAssertEqual(outcomes, [], "start の中では返さない")
    nextTurn()

    XCTAssertEqual(
      outcomes,
      [
        .failed(
          .ended(detail: ""),
          AutomationNodePass.Execution(commandLine: "pwd", ending: .workspaceMissing, count: 0),
          breach: nil)
      ])
    XCTAssertEqual(failed, #"the node "f" ended: not started (workspace missing)"#)
  }

  func testAStoppedPassWhoseWorkspaceIsGoneReturnsNothing() {
    start(command(directory: "."), .fetch, .fetch(since: nil, reachesJudge: false)).stop()
    nextTurn()

    XCTAssertEqual(outcomes, [])
  }
}
