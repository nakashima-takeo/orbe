import XCTest

@testable import Orbe

/// 会話が今もタブの前面にいると確かか（解けた待ちの ⌘T が、起きたことを貼り付けてよいか）と、休眠のタブを起こす再開に
/// 最初の入力を 1 度だけ添えること。
///
/// 壊れると何が起きるか: 終了を報告しない CLI をシェルで手で起こしたタブで、agent が終わった後のシェルに外の人が書いた
/// 文面（確認の出力）が貼り付けられ、コマンドとして実行される。休眠のタブを起こすたびに、同じ起きたことが何度も届く。
final class TerminalTabConversationTests: OrbeTestCase {
  private func report(_ tab: TerminalTab, _ agent: String) {
    tab.applyReport(AgentHookReport(agent: agent, state: "idle", sessionId: "s-1"))
  }

  func testAgentLaunchedAsTheTabCommandIsForeground() {
    let tab = TerminalTab(cwd: "/tmp", command: "/bin/codex", agent: "codex")
    report(tab, "codex")
    XCTAssertTrue(tab.conversationIsForeground)
  }

  func testCLIThatReportsItsExitIsForegroundEvenWhenStartedByHand() {
    let tab = TerminalTab(cwd: "/tmp")
    report(tab, "claude")
    XCTAssertTrue(tab.conversationIsForeground)
  }

  /// 手で起こした codex は、終わっても状態が残る（前面にはシェルがいうる）。
  func testCLIStartedByHandWithoutExitReportsIsNotForeground() {
    let byHand = TerminalTab(cwd: "/tmp")
    report(byHand, "codex")
    XCTAssertFalse(byHand.conversationIsForeground)

    let otherAgent = TerminalTab(cwd: "/tmp", command: "/bin/claude", agent: "claude")
    report(otherAgent, "codex")
    XCTAssertFalse(otherAgent.conversationIsForeground, "タブのコマンドとは別の agent の報告")
  }

  func testWakeInputIsAddedToTheResumeOnceAndMakesTheTabForeground() {
    var inputs: [String?] = []
    let tab = TerminalTab(
      restoring: TabState(
        cwd: "/tmp", agent: AgentSession(command: "codex", sessionId: "s-1"), explicitTitle: nil),
      resumeSpawn: { _, input in
        inputs.append(input)
        return ("codex resume s-1", [:])
      })

    tab.addWakeInput("レビューが付いた")
    tab.recordMaterializationStarted()
    tab.addWakeInput("起きた後の入力")
    tab.recordMaterializationStarted()

    XCTAssertEqual(inputs, ["レビューが付いた"], "起こすときに 1 度だけ添える")
    XCTAssertTrue(tab.conversationIsForeground, "復元の再開もタブのコマンドとして起こした agent")
  }
}
