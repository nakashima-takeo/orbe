import Darwin
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 会話へ今、文字を貼って Enter してよいか（秘書へ届ける・解けた待ちの続きから）を、本物の端末の前面のプロセスグループで
/// 決めることと、休眠のタブを起こす再開に最初の入力を 1 度だけ添えること。
///
/// 壊れると何が起きるか: agent を Ctrl+Z で止めた・agent が終わった後のシェルに、溜めた頼みや外の人が書いた文面（確認の
/// 出力）が貼り付けられ、コマンドとして実行される。休眠のタブを起こすたびに、同じ起きたことが何度も届く。
final class TerminalTabConversationTests: OrbeTestCase {
  func testWakeInputIsAddedToTheResumeOnce() {
    var inputs: [String?] = []
    let tab = TerminalTab(
      restoring: TabState(
        cwd: "/tmp", agent: AgentSession(command: "codex", sessionId: "s-1"), explicitTitle: nil),
      resumeSpawn: { _, _, input in
        inputs.append(input)
        return ("codex resume s-1", [:])
      })

    tab.addWakeInput("レビューが付いた")
    tab.recordMaterializationStarted()
    tab.addWakeInput("起きた後の入力")
    tab.recordMaterializationStarted()

    XCTAssertEqual(inputs, ["レビューが付いた"], "起こすときに 1 度だけ添える")
  }

  /// シェルで手で起こした agent（ここでは sleep）: 前面にいて動いている間だけ貼ってよく、Ctrl+Z で止めてシェルが前面に
  /// 戻った間・終わった後は貼らない。`fg` で戻せば、また貼ってよい。
  func testAgentStartedFromTheShellTakesInputOnlyWhileItIsTheRunningForeground() throws {
    let (controller, tab) = try openTab("/bin/zsh -f -i")
    defer { withExtendedLifetime(controller) {} }
    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) {
        (tab.surface.controlReadText(scrollback: true) ?? "").contains("%")
      }, "zsh のプロンプトが出ない")
    let shell = try foreground(tab)

    run(tab, "sleep 600")
    let agent = try foreground(tab, other: shell)
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))
    XCTAssertTrue(tab.acceptsConversationInput, "前面で動いている agent")

    kill(-agent, SIGTSTP)
    XCTAssertTrue(waitUntil { tab.surface.foregroundProcessGroup == shell }, "シェルが前面に戻る")
    XCTAssertFalse(tab.acceptsConversationInput, "Ctrl+Z で止めた後の前面はシェル")

    run(tab, "fg")
    XCTAssertTrue(waitUntil { tab.acceptsConversationInput }, "fg で戻せば、また貼ってよい")

    kill(-agent, SIGKILL)
    XCTAssertTrue(waitUntil { tab.surface.foregroundProcessGroup == shell }, "シェルが前面に戻る")
    XCTAssertFalse(tab.acceptsConversationInput, "agent が終わった後の前面はシェル")
  }

  /// タブのコマンドとして起こした agent（前面を取り返すシェルが無い）: 止まっている間は前面のままでも貼らない。
  func testStoppedAgentLaunchedAsTheTabCommandTakesNoInput() throws {
    let (controller, tab) = try openTab("/bin/sleep 600")
    defer { withExtendedLifetime(controller) {} }
    let agent = try foreground(tab)
    tab.applyReport(AgentHookReport(agent: "claude", state: "done", sessionId: "s-1"))
    XCTAssertTrue(tab.acceptsConversationInput)

    kill(-agent, SIGSTOP)
    XCTAssertTrue(waitUntil { !ProcessGroup.isRunning(agent) }, "止まる")
    XCTAssertEqual(tab.surface.foregroundProcessGroup, agent, "前提: 前面のまま")
    XCTAssertFalse(tab.acceptsConversationInput)

    kill(-agent, SIGCONT)
    XCTAssertTrue(waitUntil { tab.acceptsConversationInput }, "動き出せば、また貼ってよい")

    tab.applyReport(AgentHookReport(agent: "claude", state: "working", sessionId: "s-1"))
    XCTAssertFalse(tab.acceptsConversationInput, "作業中は貼らない")
  }

  func testProcessGroupIsRunningOnlyWhileItHasProcessesAndNoneIsStopped() throws {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("600"), nil]
    defer { argv.forEach { free($0) } }
    XCTAssertEqual(posix_spawn(&pid, "/bin/sleep", nil, &attributes, argv, environ), 0)

    XCTAssertTrue(ProcessGroup.isRunning(pid))
    kill(pid, SIGSTOP)
    var status: Int32 = 0
    waitpid(pid, &status, WUNTRACED)
    XCTAssertFalse(ProcessGroup.isRunning(pid), "止まったプロセスがいる")
    kill(pid, SIGCONT)
    XCTAssertTrue(waitUntil { ProcessGroup.isRunning(pid) })
    kill(pid, SIGKILL)
    waitpid(pid, &status, 0)
    XCTAssertFalse(ProcessGroup.isRunning(pid), "プロセスがいない")
  }

  // MARK: - 駆動

  /// 0 タブの workspace に `command` のタブを開く。タブ（surface と PTY）の寿命は controller が持つ。
  private func openTab(_ command: String) throws -> (WindowController, TerminalTab) {
    let fixture = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [])])
    try JSONEncoder().encode(fixture).write(to: workspacesFile())
    let controller = WindowController()
    let tabId = try XCTUnwrap(controller.controlSpawn(workspaceId: nil, cwd: nil, command: command))
    return (controller, try XCTUnwrap(controller.controlResolveTab(tabId)))
  }

  /// 端末の前面のプロセスグループ（`other` と違うものが現れるまで待つ）。
  private func foreground(_ tab: TerminalTab, other: pid_t? = nil) throws -> pid_t {
    var group: pid_t?
    _ = waitUntil(ControlProcess.tabSettleTimeout) {
      group = tab.surface.foregroundProcessGroup
      return group != nil && group != other
    }
    return try XCTUnwrap(group.flatMap { $0 == other ? nil : $0 }, "前面のプロセスグループが取れない")
  }

  private func run(_ tab: TerminalTab, _ line: String) {
    tab.surface.controlSendText(line)
    tab.surface.controlSendKey(ControlKey.enter)
  }
}
