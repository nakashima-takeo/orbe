import XCTest

@testable import Orbe

/// 自動化の 6 動詞のドメイン側を、実 `WindowController` 越しに固定する。起動で保存済みの部品が番人に載ること、
/// 提案と重なりが棚に出す自動化の側に出ること、拒否が制御 API の語彙になること、一覧の定義を `set_automation` へ戻せること、
/// 一覧の部品の回の記録が保存と同じ形であること。候補の付け先は今ある workspace に解けるときだけ起動ごとの id と名前で出ること。
///
/// 壊れると何が起きるか: Orbe を再起動しただけで全自動化が黙って回らなくなる。AI が自動化の棚を読んでも、提案した自動化が
/// もう取っていない提案が混ざる・取っている自動化に出ない。流している自動化への `run_automation` が別の誤りに化ける。
/// 一覧の定義を書き換えて戻すと、予定や部品が別物になる。回の記録を読む AI・秘書が、部品ごとの件数や結果を読めなくなる。
/// AI が候補の付け先を読めない、または消えた workspace を付け先として読む。
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

  /// 今の集合を取る取得の部品 `fetch` と、届いたらタスク候補を出す判定の部品 `judge`。
  static func definition(_ name: String = "受信", script: String = "true") -> AutomationDefinition {
    DesignSceneFixtures.candidatesDefinition(
      name,
      fetch: DesignSceneFixtures.commandPart(
        "fetch", "取る", .scheduled(.every(1800)), script: script, coverage: .currentSet))
  }

  static func item(_ id: String) -> AutomationItem {
    AutomationItem(id: id, link: "https://example.com/\(id)", body: "\(id) の本文", time: Date())
  }

  /// 取得の回を確定し、`proposing` があれば溜まりをすべて取った判定の回で候補にする（タイトルは `titles`、付け先は
  /// `workspaces` の順。省けば「対応: <id>」・付け先なし）。
  static func round(
    _ store: AutomationStore, _ id: Int, fetched items: [AutomationItem],
    proposing: [AutomationItem] = [], titles: [String]? = nil, workspaces: [UUID?]? = nil
  ) throws {
    let now = Date()
    _ = try store.record(
      AutomationPassEnd(
        automationId: id, part: "fetch", trigger: .schedule, startedAt: now, endedAt: now,
        take: nil, outcome: DesignSceneFixtures.fetched("fetch", items)))
    guard !proposing.isEmpty else { return }
    let taken = try store.inbox(of: "judge", in: id).map(\.seq)
    _ = try store.record(
      AutomationPassEnd(
        automationId: id, part: "judge", trigger: .arrival, startedAt: now, endedAt: now,
        take: AutomationInbox.Take(taken: taken, dropped: []),
        outcome: DesignSceneFixtures.judged(
          proposing.enumerated().map { index, item in
            DesignSceneFixtures.proposal(
              item, titles?[index] ?? "対応: \(item.id)", workspace: workspaces?[index] ?? nil)
          }, rows: taken.count)))
  }

  // MARK: - 起動

  /// 起動で保存済みの部品を番人へ載せ、過ぎていた回を走らせる。止めた自動化の部品は予定では走らない。
  func testLaunchSchedulesStoredAutomationsExceptPausedOnes() throws {
    let longAgo = Date().addingTimeInterval(-86400)
    let (active, paused) = try {
      let saved = AutomationStore()
      let active = try saved.create(Self.definition("動いている"), now: longAgo)
      let paused = try saved.create(Self.definition("止めた"), now: longAgo)
      _ = try saved.setPaused(paused.id, true)
      return (active, paused)
    }()

    let wc = try launch()

    XCTAssertTrue(wc.automationRunner.isRunning(active.id), "過ぎていた回が起動で始まる")
    XCTAssertFalse(wc.automationRunner.isRunning(paused.id), "止めた自動化は予定では走らない")
    XCTAssertTrue(
      waitUntil(10) { wc.automationStore.automation(active.id)?.runs.isEmpty == false },
      "起動で始まった回が確定しない")
    XCTAssertEqual(wc.automationStore.automation(active.id)?.runs.first?.run.trigger, .schedule)
  }

  // MARK: - 棚と重なり

  /// 提案は棚に出す自動化の側に出る。提案した自動化が取らなくなった提案は、まだ取っている自動化の棚へ移り、
  /// 重なりは両方の自動化に相手と件数で出る。
  func testProposalsAndOverlapsAppearOnTheShelfAutomation() throws {
    let wc = try launch()
    let store = wc.automationStore
    let first = try set(wc, Self.definition("受信 1"))
    let second = try set(wc, Self.definition("受信 2"))
    let kept = Self.item("kept")
    let moved = Self.item("moved")
    try Self.round(store, first, fetched: [kept, moved], proposing: [kept, moved])
    try Self.round(store, second, fetched: [moved, kept])
    try Self.round(store, first, fetched: [kept])

    XCTAssertEqual(try proposals(wc, of: first).map { $0["link"] as? String }, [kept.link])
    let shelved = try proposals(wc, of: second)
    XCTAssertEqual(
      shelved.map { $0["link"] as? String }, [moved.link], "提案した受信が取らなくなったら、取っている受信の棚へ")
    XCTAssertEqual(shelved.first?["automationId"] as? Int, second)
    XCTAssertEqual(shelved.first?["automationName"] as? String, "受信 2")

    let candidates = try listed(wc).compactMapValues { $0["taskCandidates"] as? [String: Any] }
    XCTAssertEqual(candidates[first]?["openProposals"] as? Int, 1)
    XCTAssertEqual(candidates[second]?["openProposals"] as? Int, 1)
    for (id, other, name) in [(first, second, "受信 2"), (second, first, "受信 1")] {
      let overlaps = candidates[id]?["overlaps"] as? [[String: Any]]
      XCTAssertEqual(
        overlaps?.map { $0["automationId"] as? Int }, [other], "自動化 \(id) に相手が出る")
      XCTAssertEqual(overlaps?.first?["name"] as? String, name)
      XCTAssertEqual(overlaps?.first?["count"] as? Int, 1)
    }
  }

  /// 候補を出した自動化と部品の鍵は組（`proposedBy`）で出し、棚の自動化と取り違えない。出した自動化を消した後は、棚が残っても
  /// 指す先が無いので出さない。
  func testProposedByNamesTheProposingAutomationApartFromTheShelf() throws {
    let wc = try launch()
    let store = wc.automationStore
    let first = try set(wc, Self.definition("受信 1"))
    let second = try set(wc, Self.definition("受信 2"))
    let moved = Self.item("moved")
    try Self.round(store, first, fetched: [moved], proposing: [moved])
    try Self.round(store, second, fetched: [moved])
    try Self.round(store, first, fetched: [])

    var shelved = try XCTUnwrap(try proposals(wc, of: second).first)
    XCTAssertEqual(shelved["automationId"] as? Int, second)
    XCTAssertEqual((shelved["proposedBy"] as? [String: Any])?["automationId"] as? Int, first)

    _ = wc.controlDeleteAutomation(automationId: first)
    shelved = try XCTUnwrap(try proposals(wc, of: second).first)
    XCTAssertNil(shelved["proposedBy"])
  }

  /// 候補は付け先が今ある workspace に解けるときだけ、起動ごとの id と名前を持つ（永続 ID は出さない）。付け先が無い・
  /// 消えた候補はキーごと出さない。
  func testProposalsCarryTheirWorkspaceOnlyWhenItResolves() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition())
    let main = try XCTUnwrap(wc.workspaces.first { $0.name == "main" })
    let items = ["a", "b", "c"].map { Self.item($0) }
    try Self.round(
      wc.automationStore, id, fetched: items, proposing: items,
      workspaces: [main.persistentId, nil, UUID()])

    let listed = Dictionary(
      uniqueKeysWithValues: try proposals(wc, of: id).map { ($0["title"] as? String ?? "", $0) })

    XCTAssertEqual(listed["対応: a"]?["workspaceId"] as? Int, main.id)
    XCTAssertEqual(listed["対応: a"]?["workspaceName"] as? String, "main")
    let proposedBy = listed["対応: a"]?["proposedBy"] as? [String: Any]
    XCTAssertEqual(proposedBy?["automationId"] as? Int, id)
    XCTAssertEqual(proposedBy?["partKey"] as? String, "judge")
    XCTAssertEqual(proposedBy?["sourcePartKey"] as? String, "fetch")
    for title in ["対応: b", "対応: c"] {
      XCTAssertNil(listed[title]?["workspaceId"], title)
      XCTAssertNil(listed[title]?["workspaceName"], title)
    }
  }

  // MARK: - 拒否

  /// 流している間は走っている部品が一覧にそう出て、`run_automation` は「流している途中」で断られる。
  func testFlowingAutomationIsListedAsRunningAndRefusesAnotherRun() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition(script: "sleep 30"))
    addTeardownBlock { _ = wc.controlDeleteAutomation(automationId: id) }

    _ = try success(wc.controlRunAutomation(automationId: id, partKey: nil))

    let parts = try XCTUnwrap(try listed(wc)[id]?["parts"] as? [String: [String: Any]])
    XCTAssertEqual(parts["fetch"]?["running"] as? Bool, true)
    XCTAssertEqual(parts["judge"]?["running"] as? Bool, false)
    XCTAssertEqual(code(wc.controlRunAutomation(automationId: id, partKey: "fetch")), -32000)
  }

  /// 未知の ID は -32004、不変条件に反する定義は -32602 で、受信は変わらない。
  func testRejectionsMapToTheControlVocabulary() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition())
    var codex = Self.definition("codex に判定させる")
    if case .agent(var agent) = codex.parts[1].method {
      agent.cli = "codex"
      codex.parts[1].method = .agent(agent)
    }

    XCTAssertEqual(code(wc.controlRunAutomation(automationId: 99, partKey: nil)), -32004)
    XCTAssertEqual(code(wc.controlRunAutomation(automationId: id, partKey: "nope")), -32004)
    XCTAssertEqual(code(wc.controlPauseAutomation(automationId: 99, paused: true)), -32004)
    XCTAssertEqual(code(wc.controlDeleteAutomation(automationId: 99)), -32004)
    XCTAssertEqual(code(wc.controlListAutomationProposals(automationId: 99)), -32004)
    XCTAssertEqual(
      code(wc.controlSetAutomation(automationId: 99, Self.definition())), -32004)
    XCTAssertEqual(code(wc.controlSetAutomation(automationId: id, codex)), -32602)
    XCTAssertEqual(code(wc.controlSetAutomation(automationId: nil, codex)), -32602)
    XCTAssertEqual(wc.automationStore.automations.map(\.definition), [Self.definition()])
  }

  // MARK: - 定義の往復

  /// 一覧の定義は `set_automation` と同じ形で、そのまま読み戻すと同じ定義になる（AI が読んで直して戻せる）。省略した
  /// モデルは省略のまま返る——解いた値で返すと、書き戻した定義のモデルが固定され、役割が変わっても既定が追従しない。
  func testListedDefinitionReadsBackAsTheSameDefinition() throws {
    let wc = try launch()
    let definition = AutomationDefinition(
      name: "Slack", notify: .menuBar,
      parts: [
        DesignSceneFixtures.agentPart(
          "slack", "取る", .scheduled(.cron(try BackgroundCron("30 9 * * mon-fri"))),
          tools: ["mcp__slack__search"], instruction: "自分宛の DM", coverage: .newArrivals),
        DesignSceneFixtures.commandPart(
          "narrow", "絞り込み", .arrival, from: ["slack"], script: "jq -c ."),
        DesignSceneFixtures.agentPart(
          "judge", "判定", .manual, from: ["narrow"], instruction: "判定して", deliver: .taskCandidates),
      ])
    let id = try set(wc, definition)

    let listedDefinition = try XCTUnwrap(try listed(wc)[id]?["definition"])
    let data = try JSONSerialization.data(withJSONObject: listedDefinition)

    XCTAssertEqual(
      try AutomationWire.decoder.decode(AutomationDefinition.self, from: data), definition)
  }

  /// 一覧の回の記録は部品ごとに、保存と同じ形（取った件数・実行の記録・役割ごとの結果）。
  func testListedRunsKeepTheStoredShape() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition())
    let a = Self.item("a")
    try Self.round(wc.automationStore, id, fetched: [a], proposing: [a])

    let parts = try XCTUnwrap(try listed(wc)[id]?["parts"] as? [String: [String: Any]])
    let judged = try XCTUnwrap((parts["judge"]?["runs"] as? [[String: Any]])?.first)

    XCTAssertEqual(
      Set(judged.keys), ["startedAt", "endedAt", "trigger", "taken", "execution", "result"])
    XCTAssertEqual(judged["taken"] as? Int, 1)
    XCTAssertEqual((judged["execution"] as? [String: Any])?["commandLine"] as? String, "claude -p")
    let result = try XCTUnwrap(judged["result"] as? [String: Any])
    XCTAssertEqual(result["kind"] as? String, "judge")
    XCTAssertEqual(result["proposed"] as? Int, 1)
    XCTAssertEqual(parts["judge"]?["inbox"] as? Int, 0)
    XCTAssertNil(parts["fetch"]?["inbox"], "入力の無い部品は溜まりを持たない")

    let fetched = try XCTUnwrap((parts["fetch"]?["runs"] as? [[String: Any]])?.first)
    XCTAssertEqual(
      Set(fetched.keys),
      ["startedAt", "endedAt", "trigger", "execution", "result", "stacked", "withdrawn"])
    XCTAssertEqual((fetched["execution"] as? [String: Any])?["count"] as? Int, 1)
    XCTAssertEqual(fetched["stacked"] as? Int, 1)
    let fetchResult = try XCTUnwrap(fetched["result"] as? [String: Any])
    XCTAssertEqual(fetchResult["kind"] as? String, "fetch")
    XCTAssertEqual(fetchResult["fresh"] as? Int, 1)
  }
}
