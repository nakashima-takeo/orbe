import AppKit
import XCTest

@testable import Orbe

/// 待ちの条件の制御 API 側（呼び出し元タブから作業ディレクトリと会話を入れる・一覧の形）と、付けた条件を窓が裏で
/// 確かめること。
///
/// 壊れると何が起きるか: 人がシェルから付けた条件が、たまたまそのタブにいた agent の会話のものとして残り、⌘T が別の
/// 会話を再開する。条件と経過が一覧に出ず、AI が同じ条件で付け直せない。付けた条件が一度も確かめられず、いつまでも
/// 解けない。
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

  // MARK: - 確かめる

  func testWindowChecksTheConditionInTheBackgroundAndResolvesTheWait() throws {
    let wc = try launch()
    var draft = TaskDraft(title: "設定の検索を速くする")
    draft.waitingReason = "レビュー待ち"
    draft.waitingCondition = condition()
    draft.waitingCondition?.command = "echo レビューが付いた"
    _ = try success(wc.controlAddTask(draft, workspaceId: nil, callerTabId: nil))

    XCTAssertTrue(
      waitUntil { wc.taskStore.tasks.first?.waitResolution != nil }, "付けた直後に確かめて解ける")
    XCTAssertEqual(wc.taskStore.tasks.first?.waitResolution?.headline, "レビューが付いた")
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
}
