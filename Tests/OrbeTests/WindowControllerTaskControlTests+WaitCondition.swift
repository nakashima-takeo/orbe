import AppKit
import XCTest

@testable import Orbe

/// 待ちの条件の制御 API 側（呼び出し元タブから作業ディレクトリと会話を入れる・一覧の形）と、解けた待ちの ⌘T が開いた
/// ままの会話のタブへ届けるかどうか。
///
/// 壊れると何が起きるか: 人がシェルから付けた条件が、たまたまそのタブにいた agent の会話のものとして残り、⌘T が別の
/// 会話を再開する。条件と経過が一覧に出ず、AI が同じ条件で付け直せない。手で起こした codex が去った後のシェルや、
/// 作業中の agent に、起きたことが貼り付けられる。
extension WindowControllerTaskControlTests {
  private func condition(deadlineIn: TimeInterval = 3600) -> WaitConditionRequest {
    WaitConditionRequest(
      description: "レビューが付いたら", command: "exit 1", intervalMinutes: 10,
      deadline: Date().addingTimeInterval(deadlineIn))
  }

  private func addWaiting(_ wc: WindowController, callerTabId: Int?) throws -> Int {
    var draft = TaskDraft(title: "設定の検索を速くする")
    draft.waitingReason = "レビュー待ち"
    draft.waitingCondition = condition()
    let added = try success(
      wc.controlAddTask(draft, workspaceId: nil, callerTabId: callerTabId))
    return try XCTUnwrap((added["task"] as? [String: Any])?["taskId"] as? Int)
  }

  private func listedCondition(_ wc: WindowController) throws -> [String: Any] {
    let waiting = try XCTUnwrap(try listed(wc).first?["waiting"] as? [String: Any])
    return try XCTUnwrap(waiting["condition"] as? [String: Any])
  }

  private func report(_ wc: WindowController, _ tab: TerminalTab, _ agent: String, _ state: String)
  {
    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: agent, state: state, sessionId: "s-1"))
  }

  // MARK: - 付ける

  func testConditionFromAWorkingAgentRecordsItsConversationAndDirectory() throws {
    let wc = try launch()
    let tab = try backgroundTab(wc)
    report(wc, tab, "claude", "working")

    _ = try addWaiting(wc, callerTabId: tab.id)

    let listed = try listedCondition(wc)
    XCTAssertEqual(listed["description"] as? String, "レビューが付いたら")
    XCTAssertEqual(listed["command"] as? String, "exit 1")
    XCTAssertEqual(listed["intervalMinutes"] as? Int, 10)
    XCTAssertEqual(listed["directory"] as? String, tab.cwd, "呼び出し元タブの作業ディレクトリで走る")
    XCTAssertEqual(
      listed["agent"] as? [String: String], ["command": "claude", "sessionId": "s-1"])
    XCTAssertEqual(listed["checks"] as? Int, 0)
  }

  /// 会話を残すのは、呼び出し元タブの agent が作業中を報告しているときだけ。
  func testConditionFromATabWhoseAgentIsNotWorkingRecordsNoConversation() throws {
    let wc = try launch()
    let tab = try backgroundTab(wc)
    report(wc, tab, "codex", "idle")

    _ = try addWaiting(wc, callerTabId: tab.id)

    let listed = try listedCondition(wc)
    XCTAssertNil(listed["agent"])
    XCTAssertEqual(listed["directory"] as? String, tab.cwd)
  }

  func testUpdateReadsTheCallerTabAndRejectsConditionsTheStoreRefuses() throws {
    let wc = try launch()
    let tab = try backgroundTab(wc)
    report(wc, tab, "claude", "working")
    let id = try XCTUnwrap(try added(wc)["taskId"] as? Int)

    var withoutWait = TaskUpdate()
    withoutWait.waitingCondition = .set(condition())
    XCTAssertEqual(
      code(wc.controlUpdateTask(taskId: id, withoutWait, workspaceId: nil, callerTabId: tab.id)),
      -32602, "待っていないタスクには付けられない")

    var past = TaskUpdate(waitingReason: .set("返事"))
    past.waitingCondition = .set(condition(deadlineIn: -60))
    XCTAssertEqual(
      code(wc.controlUpdateTask(taskId: id, past, workspaceId: nil, callerTabId: tab.id)), -32602,
      "過ぎた期限は付けられない")

    var update = TaskUpdate(waitingReason: .set("返事"))
    update.waitingCondition = .set(condition())
    _ = try success(
      wc.controlUpdateTask(taskId: id, update, workspaceId: nil, callerTabId: tab.id))
    XCTAssertEqual(
      try listedCondition(wc)["agent"] as? [String: String],
      ["command": "claude", "sessionId": "s-1"])
  }

  func testResolvedWaitIsListedWithItsConditionInsteadOfTheWait() throws {
    let wc = try launch()
    let id = try addWaiting(wc, callerTabId: nil)
    let conditionId = try XCTUnwrap(wc.taskStore.tasks.first?.waiting?.condition?.id)
    let now = Date()
    wc.taskStore.recordCheck(
      id, condition: conditionId,
      BackgroundRunResult(
        commandLine: "exit 1", startedAt: now, endedAt: now, ending: .exited(0),
        output: .command(stdout: .init(data: Data("レビューが付いた\n".utf8)), stderr: .init())))

    let task = try XCTUnwrap(try listed(wc).first)
    XCTAssertNil(task["waiting"])
    let resolved = try XCTUnwrap(task["waitResolved"] as? [String: Any])
    XCTAssertEqual(resolved["how"] as? String, "satisfied")
    XCTAssertEqual(resolved["output"] as? String, "レビューが付いた\n")
    let waiting = try XCTUnwrap(resolved["waiting"] as? [String: Any])
    XCTAssertEqual(waiting["reason"] as? String, "レビュー待ち")
    let condition = try XCTUnwrap(waiting["condition"] as? [String: Any])
    XCTAssertEqual(condition["checks"] as? Int, 1)
    XCTAssertEqual((condition["lastCheck"] as? [String: Any])?["result"] as? String, "success")
  }

  // MARK: - ⌘T で続きから（開いたままの会話のタブ）

  /// 前面のタブで claude が作業中に条件を付け、条件を満たした状態にする。
  private func resolvedFromFrontTab(_ wc: WindowController) throws -> (Int, TerminalTab) {
    let tab = try XCTUnwrap(wc.current.tabs.first)
    report(wc, tab, "claude", "working")
    let id = try addWaiting(wc, callerTabId: tab.id)
    let conditionId = try XCTUnwrap(wc.taskStore.tasks.first?.waiting?.condition?.id)
    let now = Date()
    wc.taskStore.recordCheck(
      id, condition: conditionId,
      BackgroundRunResult(
        commandLine: "exit 1", startedAt: now, endedAt: now, ending: .exited(0), output: .none))
    return (id, tab)
  }

  private func deliver(_ wc: WindowController, _ id: Int) -> TaskPaletteError? {
    wc.refreshChrome()
    wc.flushChrome()
    return wc.continueWait(taskId: id)
  }

  func testOpenConversationThatCanTakeInputGetsWhatHappened() throws {
    let wc = try launch()
    let (id, tab) = try resolvedFromFrontTab(wc)
    XCTAssertNotNil(tab.surface.surfacePtr, "前提: 前面のタブは mount 済み")
    report(wc, tab, "claude", "idle")

    XCTAssertNil(deliver(wc, id))

    XCTAssertNil(wc.taskStore.tasks.first { $0.id == id }?.wait, "届けたら起きたことは消える")
  }

  /// 作業中・確認待ちの agent や、会話が前面にいると確かでないタブ（手で起こした codex）には貼り付けず、移るだけ。
  func testBusyOrUncertainConversationOnlyGetsFocused() throws {
    let wc = try launch()
    let (id, tab) = try resolvedFromFrontTab(wc)

    for (agent, state) in [("claude", "working"), ("claude", "waiting"), ("codex", "idle")] {
      report(wc, tab, agent, state)
      XCTAssertNil(deliver(wc, id))
      XCTAssertNotNil(
        wc.taskStore.tasks.first { $0.id == id }?.waitResolution,
        "\(agent) \(state): 起きたことは残る（もう一度 ⌘T を押せる）")
    }
  }
}
