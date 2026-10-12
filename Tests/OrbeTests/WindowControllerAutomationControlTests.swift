import XCTest

@testable import Orbe

/// 受信の 6 動詞のドメイン側を、実 `WindowController` 越しに固定する。起動で保存済みの受信が番人に載ること、
/// 提案と重なりが棚に出す受信の側に出ること、拒否が制御 API の語彙になること、一覧の定義を `set_intake` へ戻せること、
/// 一覧の回の記録が旧い形のままであること。
///
/// 壊れると何が起きるか: Orbe を再起動しただけで全受信が黙って回らなくなる。AI が受信の棚を読んでも、提案した受信が
/// もう取っていない提案が混ざる・取っている受信に出ない。走っている受信への `run_intake` が別の誤りに化ける。一覧の定義を
/// 書き換えて戻すと、間隔や取得役が別物になる。回の記録を読む AI・秘書が、件数や判定の結果を読めなくなる。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerAutomationControlTests: OrbeTestCase {
  private func launch() throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  private func success(
    _ result: Result<Any, ControlError>, file: StaticString = #filePath, line: UInt = #line
  ) throws -> [String: Any] {
    switch result {
    case .success(let value):
      return try XCTUnwrap(value as? [String: Any], file: file, line: line)
    case .failure(let error):
      XCTFail("失敗した: \(error.code) \(error.message)", file: file, line: line)
      return [:]
    }
  }

  private func code(_ result: Result<Any, ControlError>) -> Int? {
    if case .failure(let error) = result { return error.code }
    return nil
  }

  private func listed(_ wc: WindowController) throws -> [Int: [String: Any]] {
    let automations = try XCTUnwrap(
      success(wc.controlListAutomations())["intakes"] as? [[String: Any]])
    return Dictionary(uniqueKeysWithValues: automations.map { ($0["intakeId"] as? Int ?? 0, $0) })
  }

  private func proposals(_ wc: WindowController, of automationId: Int) throws -> [[String: Any]] {
    try XCTUnwrap(
      success(wc.controlListAutomationProposals(automationId: automationId))["proposals"]
        as? [[String: Any]])
  }

  private func set(_ wc: WindowController, _ definition: AutomationDefinition) throws -> Int {
    try XCTUnwrap(
      (success(wc.controlSetAutomation(automationId: nil, definition))["intake"] as? [String: Any])?[
        "intakeId"] as? Int)
  }

  /// 成功した回を確定する（`proposing` の項目に提案を出す）。
  private func commit(
    _ wc: WindowController, _ id: Int, fetched: [AutomationItem], proposing: [AutomationItem] = []
  ) {
    AutomationStoreTests.commit(
      wc.automationStore, id, AutomationStoreTests.run(at: Date()), fetched: fetched,
      decisions: proposing.map { .propose(itemId: $0.id, title: "対応: \($0.id)", due: nil) })
  }

  // MARK: - 起動

  /// 起動で保存済みの受信を番人へ載せ、過ぎていた回を走らせる。止めた受信は予定では走らない。
  func testLaunchSchedulesStoredAutomationsExceptPausedOnes() throws {
    let longAgo = Date().addingTimeInterval(-86400)
    let saved = AutomationStore(file: nil)
    let active = try saved.create(
      AutomationStoreTests.definition("動いている", script: "true"), now: longAgo)
    let paused = try saved.create(
      AutomationStoreTests.definition("止めた", script: "true"), now: longAgo)
    _ = try saved.setPaused(paused.id, true)

    let wc = try launch()

    XCTAssertTrue(wc.automationRunner.isRunning(active.id), "過ぎていた回が起動で始まる")
    XCTAssertFalse(wc.automationRunner.isRunning(paused.id), "止めた受信は予定では走らない")
    XCTAssertTrue(
      waitUntil(10) { wc.automationStore.automation(active.id)?.runs.isEmpty == false },
      "起動で始まった回が確定しない")
    XCTAssertEqual(wc.automationStore.automation(active.id)?.runs.first?.trigger, .schedule)
  }

  // MARK: - 棚と重なり

  /// 提案は棚に出す受信の側に出る。提案した受信が取らなくなった提案は、まだ取っている受信の棚へ移り、
  /// 重なりは両方の受信に相手と件数で出る。
  func testProposalsAndOverlapsAppearOnTheShelfAutomation() throws {
    let wc = try launch()
    let first = try set(wc, AutomationStoreTests.definition("受信 1"))
    let second = try set(wc, AutomationStoreTests.definition("受信 2"))
    let kept = AutomationStoreTests.item("kept")
    let moved = AutomationStoreTests.item("moved")
    commit(wc, first, fetched: [kept, moved], proposing: [kept, moved])
    commit(wc, second, fetched: [moved, kept])
    commit(wc, first, fetched: [kept])

    XCTAssertEqual(try proposals(wc, of: first).map { $0["link"] as? String }, [kept.link])
    let shelved = try proposals(wc, of: second)
    XCTAssertEqual(
      shelved.map { $0["link"] as? String }, [moved.link], "提案した受信が取らなくなったら、取っている受信の棚へ")
    XCTAssertEqual(shelved.first?["intakeId"] as? Int, second)
    XCTAssertEqual(shelved.first?["intakeName"] as? String, "受信 2")

    let automations = try listed(wc)
    XCTAssertEqual(automations[first]?["openProposals"] as? Int, 1)
    XCTAssertEqual(automations[second]?["openProposals"] as? Int, 1)
    for (id, other, name) in [(first, second, "受信 2"), (second, first, "受信 1")] {
      let overlaps = automations[id]?["overlaps"] as? [[String: Any]]
      XCTAssertEqual(overlaps?.map { $0["intakeId"] as? Int }, [other], "受信 \(id) に相手が出る")
      XCTAssertEqual(overlaps?.first?["name"] as? String, name)
      XCTAssertEqual(overlaps?.first?["count"] as? Int, 1)
    }
  }

  // MARK: - 拒否

  /// 走っている回がある間は一覧にそう出て、`run_intake` は「実行できない」で断られる。
  func testRunningAutomationIsListedAsRunningAndRefusesRunNow() throws {
    let wc = try launch()
    let id = try set(wc, AutomationStoreTests.definition(script: "sleep 30"))
    addTeardownBlock { _ = wc.controlDeleteAutomation(automationId: id) }

    _ = try success(wc.controlRunAutomation(automationId: id))

    XCTAssertEqual(try listed(wc)[id]?["running"] as? Bool, true)
    XCTAssertEqual(code(wc.controlRunAutomation(automationId: id)), -32000)
  }

  /// 未知の ID は -32004、不変条件に反する定義は -32602 で、受信は変わらない。
  func testRejectionsMapToTheControlVocabulary() throws {
    let wc = try launch()
    let id = try set(wc, AutomationStoreTests.definition())
    var codex = AutomationStoreTests.definition("codex に判定させる")
    codex.steps = [AutomationStoreTests.judgeStep(cli: "codex")]

    XCTAssertEqual(code(wc.controlRunAutomation(automationId: 99)), -32004)
    XCTAssertEqual(code(wc.controlPauseAutomation(automationId: 99, paused: true)), -32004)
    XCTAssertEqual(code(wc.controlDeleteAutomation(automationId: 99)), -32004)
    XCTAssertEqual(code(wc.controlListAutomationProposals(automationId: 99)), -32004)
    XCTAssertEqual(
      code(wc.controlSetAutomation(automationId: 99, AutomationStoreTests.definition())), -32004)
    XCTAssertEqual(code(wc.controlSetAutomation(automationId: id, codex)), -32602)
    XCTAssertEqual(code(wc.controlSetAutomation(automationId: nil, codex)), -32602)
    XCTAssertEqual(
      wc.automationStore.automations.map(\.definition), [AutomationStoreTests.definition()])
  }

  // MARK: - 定義の往復

  /// 一覧の定義は `set_intake` と同じ形で、そのまま読み戻すと同じ定義になる（AI が読んで直して戻せる）。
  func testListedDefinitionReadsBackAsTheSameDefinition() throws {
    let wc = try launch()
    var definition = AutomationStoreTests.definition(
      trigger: .daily([.init(hour: 13, minute: 30), .init(hour: 9, minute: 0)]))
    definition.source?.method = AutomationStoreTests.agentSource()
    let id = try set(wc, definition)

    let entry = try XCTUnwrap(try listed(wc)[id])
    let data = try JSONSerialization.data(withJSONObject: entry)

    XCTAssertEqual(
      try AutomationWire.decoder.decode(AutomationLegacyDefinition.self, from: data).definition,
      definition)
  }

  /// 一覧の回の記録は旧い形（取得・新しい件数・判定・下げた数）のまま。
  func testListedRunsKeepTheLegacyShape() throws {
    let wc = try launch()
    let id = try set(wc, AutomationStoreTests.definition())
    let a = AutomationStoreTests.item("a")
    var run = AutomationStoreTests.run(at: Date())
    run.source?.count = 1
    run.fresh = 1
    run.steps = [
      AutomationStepReport(
        name: "判定", commandLine: "claude -p", ending: "exited 0", count: 1,
        rejected: AutomationRejections())
    ]
    AutomationStoreTests.commit(
      wc.automationStore, id, run, fetched: [a],
      decisions: [.propose(itemId: "a", title: "対応する", due: nil)])

    let listedRun = try XCTUnwrap((try listed(wc)[id]?["runs"] as? [[String: Any]])?.first)

    XCTAssertEqual(
      Set(listedRun.keys),
      ["startedAt", "endedAt", "trigger", "fetch", "newItems", "judge", "withdrawn"])
    XCTAssertEqual((listedRun["fetch"] as? [String: Any])?["items"] as? Int, 1)
    XCTAssertEqual(listedRun["newItems"] as? Int, 1)
    let judge = try XCTUnwrap(listedRun["judge"] as? [String: Any])
    XCTAssertEqual(judge["commandLine"] as? String, "claude -p")
    XCTAssertEqual(judge["proposed"] as? Int, 1)
  }
}
