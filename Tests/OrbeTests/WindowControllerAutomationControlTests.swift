import XCTest

@testable import Orbe

/// 自動化の 6 動詞のドメイン側を、実 `WindowController` 越しに固定する。起動で保存済みの自動化が番人に載ること、
/// 提案と重なりが棚に出す自動化の側に出ること、拒否が制御 API の語彙になること、一覧の定義を `set_automation` へ戻せること、
/// 一覧の回の記録が保存と同じ形であること。
///
/// 壊れると何が起きるか: Orbe を再起動しただけで全自動化が黙って回らなくなる。AI が自動化の棚を読んでも、提案した自動化が
/// もう取っていない提案が混ざる・取っている自動化に出ない。走っている自動化への `run_automation` が別の誤りに化ける。
/// 一覧の定義を書き換えて戻すと、間隔や取得元が別物になる。回の記録を読む AI・秘書が、段ごとの件数や出力先の結果を読めなくなる。
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
      success(wc.controlListAutomations())["automations"] as? [[String: Any]])
    return Dictionary(
      uniqueKeysWithValues: automations.map { ($0["automationId"] as? Int ?? 0, $0) })
  }

  private func proposals(_ wc: WindowController, of automationId: Int) throws -> [[String: Any]] {
    try XCTUnwrap(
      success(wc.controlListAutomationProposals(automationId: automationId))["proposals"]
        as? [[String: Any]])
  }

  private func set(_ wc: WindowController, _ definition: AutomationDefinition) throws -> Int {
    try XCTUnwrap(
      (success(wc.controlSetAutomation(automationId: nil, definition))["automation"]
        as? [String: Any])?["automationId"] as? Int)
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
    XCTAssertEqual(shelved.first?["automationId"] as? Int, second)
    XCTAssertEqual(shelved.first?["automationName"] as? String, "受信 2")

    let candidates = try listed(wc).mapValues { $0["taskCandidates"] as? [String: Any] }
    XCTAssertEqual(candidates[first]??["openProposals"] as? Int, 1)
    XCTAssertEqual(candidates[second]??["openProposals"] as? Int, 1)
    for (id, other, name) in [(first, second, "受信 2"), (second, first, "受信 1")] {
      let overlaps = candidates[id]??["overlaps"] as? [[String: Any]]
      XCTAssertEqual(
        overlaps?.map { $0["automationId"] as? Int }, [other], "自動化 \(id) に相手が出る")
      XCTAssertEqual(overlaps?.first?["name"] as? String, name)
      XCTAssertEqual(overlaps?.first?["count"] as? Int, 1)
    }
  }

  // MARK: - 拒否

  /// 走っている回がある間は一覧にそう出て、`run_automation` は「実行できない」で断られる。
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

  /// 一覧の定義は `set_automation` と同じ形で、そのまま読み戻すと同じ定義になる（AI が読んで直して戻せる）。省略した
  /// モデルは省略のまま返る——解いた値で返すと、書き戻した定義のモデルが固定され、段を並べ替えても既定が追従しない。
  func testListedDefinitionReadsBackAsTheSameDefinition() throws {
    let wc = try launch()
    var definition = AutomationStoreTests.definition(
      trigger: .daily([.init(hour: 13, minute: 30), .init(hour: 9, minute: 0)]))
    definition.source?.method = .agent(
      AutomationSourceAgent(
        cli: "claude", model: nil, tools: ["mcp__slack__search"], request: "自分宛の DM"))
    definition.steps = [
      AutomationStep(name: "絞り込み", method: .command(BackgroundCommand(script: "jq -c ."))),
      AutomationStep(
        name: "判定",
        method: .agent(AutomationStepAgent(cli: "claude", model: nil, instruction: "判定して"))),
    ]
    let id = try set(wc, definition)

    let listedDefinition = try XCTUnwrap(try listed(wc)[id]?["definition"])
    let data = try JSONSerialization.data(withJSONObject: listedDefinition)

    XCTAssertEqual(
      try AutomationWire.decoder.decode(AutomationDefinition.self, from: data), definition)
  }

  /// 一覧の回の記録は保存と同じ形（取得元・新しい件数・各段・出力先）。
  func testListedRunsKeepTheStoredShape() throws {
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
      Set(listedRun.keys), ["startedAt", "endedAt", "trigger", "source", "fresh", "steps", "sink"])
    XCTAssertEqual((listedRun["source"] as? [String: Any])?["count"] as? Int, 1)
    XCTAssertEqual(listedRun["fresh"] as? Int, 1)
    let step = try XCTUnwrap((listedRun["steps"] as? [[String: Any]])?.first)
    XCTAssertEqual(step["name"] as? String, "判定")
    XCTAssertEqual(step["commandLine"] as? String, "claude -p")
    let sink = try XCTUnwrap(listedRun["sink"] as? [String: Any])
    XCTAssertEqual(sink["kind"] as? String, "taskCandidates")
    XCTAssertEqual(sink["proposed"] as? Int, 1)
  }
}
