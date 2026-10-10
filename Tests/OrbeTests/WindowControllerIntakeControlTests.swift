import XCTest

@testable import Orbe

/// 受信の 6 動詞のドメイン側を、実 `WindowController` 越しに固定する。起動で保存済みの受信が番人に載ること、
/// 提案と重なりが棚に出す受信の側に出ること、拒否が制御 API の語彙になること、一覧の定義を `set_intake` へ戻せること。
///
/// 壊れると何が起きるか: Orbe を再起動しただけで全受信が黙って回らなくなる。AI が受信の棚を読んでも、提案した受信が
/// もう取っていない提案が混ざる・取っている受信に出ない。走っている受信への `run_intake` が別の誤りに化ける。一覧の定義を
/// 書き換えて戻すと、間隔や取得役が別物になる。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerIntakeControlTests: OrbeTestCase {
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
    let intakes = try XCTUnwrap(success(wc.controlListIntakes())["intakes"] as? [[String: Any]])
    return Dictionary(uniqueKeysWithValues: intakes.map { ($0["intakeId"] as? Int ?? 0, $0) })
  }

  private func proposals(_ wc: WindowController, of intakeId: Int) throws -> [[String: Any]] {
    try XCTUnwrap(
      success(wc.controlListIntakeProposals(intakeId: intakeId))["proposals"] as? [[String: Any]])
  }

  private func set(_ wc: WindowController, _ definition: IntakeDefinition) throws -> Int {
    try XCTUnwrap(
      (success(wc.controlSetIntake(intakeId: nil, definition))["intake"] as? [String: Any])?[
        "intakeId"] as? Int)
  }

  /// 成功した回を確定する（`proposing` の項目に提案を出す）。
  private func commit(
    _ wc: WindowController, _ id: Int, fetched: [IntakeItem], proposing: [IntakeItem] = []
  ) {
    let now = Date()
    let run = IntakeRun(
      startedAt: now, endedAt: now, trigger: .now,
      fetch: IntakeFetchReport(
        commandLine: "fetch", ending: "exited 0", items: fetched.count,
        rejected: IntakeRejections()),
      newItems: proposing.count,
      judge: IntakeJudgeReport(
        commandLine: "claude", ending: "exited 0", proposed: 0, resolved: 0,
        rejected: IntakeRejections()),
      withdrawn: 0, failure: nil)
    wc.intakeStore.commit(
      id, run, fetched: fetched, judged: proposing,
      decisions: proposing.map { .propose(itemId: $0.id, title: "対応: \($0.id)", due: nil) })
  }

  // MARK: - 起動

  /// 起動で保存済みの受信を番人へ載せ、過ぎていた回を走らせる。止めた受信は予定では走らない。
  func testLaunchSchedulesStoredIntakesExceptPausedOnes() throws {
    let longAgo = Date().addingTimeInterval(-86400)
    let saved = IntakeStore(file: nil)
    let active = try saved.create(
      IntakeStoreTests.definition("動いている", script: "true"), now: longAgo)
    let paused = try saved.create(
      IntakeStoreTests.definition("止めた", script: "true"), now: longAgo)
    _ = try saved.setPaused(paused.id, true)

    let wc = try launch()

    XCTAssertTrue(wc.intakeRunner.isRunning(active.id), "過ぎていた回が起動で始まる")
    XCTAssertFalse(wc.intakeRunner.isRunning(paused.id), "止めた受信は予定では走らない")
    XCTAssertTrue(
      waitUntil(10) { wc.intakeStore.intake(active.id)?.runs.isEmpty == false }, "起動で始まった回が確定しない")
    XCTAssertEqual(wc.intakeStore.intake(active.id)?.runs.first?.trigger, .schedule)
  }

  // MARK: - 棚と重なり

  /// 提案は棚に出す受信の側に出る。提案した受信が取らなくなった提案は、まだ取っている受信の棚へ移り、
  /// 重なりは両方の受信に相手と件数で出る。
  func testProposalsAndOverlapsAppearOnTheShelfIntake() throws {
    let wc = try launch()
    let first = try set(wc, IntakeStoreTests.definition("受信 1"))
    let second = try set(wc, IntakeStoreTests.definition("受信 2"))
    let kept = IntakeStoreTests.item("kept")
    let moved = IntakeStoreTests.item("moved")
    commit(wc, first, fetched: [kept, moved], proposing: [kept, moved])
    commit(wc, second, fetched: [moved, kept])
    commit(wc, first, fetched: [kept])

    XCTAssertEqual(try proposals(wc, of: first).map { $0["link"] as? String }, [kept.link])
    let shelved = try proposals(wc, of: second)
    XCTAssertEqual(
      shelved.map { $0["link"] as? String }, [moved.link], "提案した受信が取らなくなったら、取っている受信の棚へ")
    XCTAssertEqual(shelved.first?["intakeId"] as? Int, second)
    XCTAssertEqual(shelved.first?["intakeName"] as? String, "受信 2")

    let intakes = try listed(wc)
    XCTAssertEqual(intakes[first]?["openProposals"] as? Int, 1)
    XCTAssertEqual(intakes[second]?["openProposals"] as? Int, 1)
    for (id, other, name) in [(first, second, "受信 2"), (second, first, "受信 1")] {
      let overlaps = intakes[id]?["overlaps"] as? [[String: Any]]
      XCTAssertEqual(overlaps?.map { $0["intakeId"] as? Int }, [other], "受信 \(id) に相手が出る")
      XCTAssertEqual(overlaps?.first?["name"] as? String, name)
      XCTAssertEqual(overlaps?.first?["count"] as? Int, 1)
    }
  }

  // MARK: - 拒否

  /// 走っている回がある間は一覧にそう出て、`run_intake` は「実行できない」で断られる。
  func testRunningIntakeIsListedAsRunningAndRefusesRunNow() throws {
    let wc = try launch()
    let id = try set(wc, IntakeStoreTests.definition(script: "sleep 30"))
    addTeardownBlock { _ = wc.controlDeleteIntake(intakeId: id) }

    _ = try success(wc.controlRunIntake(intakeId: id))

    XCTAssertEqual(try listed(wc)[id]?["running"] as? Bool, true)
    XCTAssertEqual(code(wc.controlRunIntake(intakeId: id)), -32000)
  }

  /// 未知の ID は -32004、不変条件に反する定義は -32602 で、受信は変わらない。
  func testRejectionsMapToTheControlVocabulary() throws {
    let wc = try launch()
    let id = try set(wc, IntakeStoreTests.definition())
    var codex = IntakeStoreTests.definition("codex に判定させる")
    codex.judge.cli = "codex"

    XCTAssertEqual(code(wc.controlRunIntake(intakeId: 99)), -32004)
    XCTAssertEqual(code(wc.controlPauseIntake(intakeId: 99, paused: true)), -32004)
    XCTAssertEqual(code(wc.controlDeleteIntake(intakeId: 99)), -32004)
    XCTAssertEqual(code(wc.controlListIntakeProposals(intakeId: 99)), -32004)
    XCTAssertEqual(code(wc.controlSetIntake(intakeId: 99, IntakeStoreTests.definition())), -32004)
    XCTAssertEqual(code(wc.controlSetIntake(intakeId: id, codex)), -32602)
    XCTAssertEqual(code(wc.controlSetIntake(intakeId: nil, codex)), -32602)
    XCTAssertEqual(wc.intakeStore.intakes.map(\.definition), [IntakeStoreTests.definition()])
  }

  // MARK: - 定義の往復

  /// 一覧の定義は `set_intake` と同じ形で、そのまま読み戻すと同じ定義になる（AI が読んで直して戻せる）。
  func testListedDefinitionReadsBackAsTheSameDefinition() throws {
    let wc = try launch()
    var definition = IntakeStoreTests.definition(
      when: .daily([.init(hour: 13, minute: 30), .init(hour: 9, minute: 0)]))
    definition.fetch.method = .agent(
      IntakeAgentFetch(
        cli: "claude", model: "haiku", tools: ["mcp__slack__search"], request: "自分宛の DM"))
    let id = try set(wc, definition)

    let entry = try XCTUnwrap(try listed(wc)[id])
    let data = try JSONSerialization.data(withJSONObject: entry)

    XCTAssertEqual(try IntakeWire.decoder.decode(IntakeDefinition.self, from: data), definition)
  }
}
