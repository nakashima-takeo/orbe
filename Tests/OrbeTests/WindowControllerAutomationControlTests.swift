import XCTest

@testable import Orbe

/// 自動化の 8 動詞のドメイン側を、実 `WindowController` 越しに固定する。起動で保存済みの部品が番人に載ること、
/// 提案と重なりが棚に出す自動化の側に出ること、拒否が制御 API の語彙になること、一覧の定義を `set_automation` へ戻せること。
/// 候補の付け先は今ある workspace に解けるときだけ起動ごとの id と名前で、候補にした理由は判定が書いたときだけ出ること。
/// 試走は始めた応答で道の上の部品を返し、待って読むと部品ごとの回の結果（取得の rows・止めた副作用の held.rows）を返し、
/// 始める前と自動化を消した後は -32004 で読めないこと。
///
/// 壊れると何が起きるか: Orbe を再起動しただけで全自動化が黙って回らなくなる。AI が自動化の棚を読んでも、提案した自動化が
/// もう取っていない提案が混ざる・取っている自動化に出ない。流している自動化への `run_automation` が別の誤りに化ける。
/// 一覧の定義を書き換えて戻すと、予定や部品が別物になる。
/// AI が候補の付け先や候補にした理由を読めない、または消えた workspace を付け先として読む。AI が試走を始めても結果を読めない、止めた副作用に
/// 何が渡るはずだったかを確かめられず本番で初めて誤りに気づく、試走をまだ始めていないのに自動化が無いと読んで作り直す。
///
/// 重要: 実 NSWindow に SurfaceView を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerAutomationControlTests: OrbeTestCase {
  func launch() throws -> WindowController {
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

  func success(
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

  func listed(_ wc: WindowController) throws -> [Int: [String: Any]] {
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

  func set(_ wc: WindowController, _ definition: AutomationDefinition) throws -> Int {
    try XCTUnwrap(
      (success(wc.controlSetAutomation(automationId: nil, version: nil, definition))["automation"]
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
  /// `workspaces`、候補にした理由は `reasons` の順。省けば「対応: <id>」・付け先なし・理由なし）。
  static func round(
    _ store: AutomationStore, _ id: Int, fetched items: [AutomationItem],
    proposing: [AutomationItem] = [], titles: [String]? = nil, workspaces: [UUID?]? = nil,
    reasons: [String?]? = nil
  ) throws {
    let now = Date()
    try store.record(id, part: "fetch", at: now, outcome: DesignSceneFixtures.fetched(items))
    guard !proposing.isEmpty else { return }
    let judge = store.part(id, "judge")
    let taken = try XCTUnwrap(store.read(judge, of: id, baseline: nil, now: now)).taken
    let proposals = proposing.enumerated().compactMap { pair -> AutomationPartPass.Proposal? in
      let (index, item) = pair
      guard let origin = taken.first(where: { $0.origin?.item.id == item.id })?.origin else {
        return nil
      }
      return AutomationPartPass.Proposal(
        origin: origin, title: titles?[index] ?? "対応: \(item.id)",
        due: nil, workspace: workspaces?[index] ?? nil, reason: reasons?[index] ?? nil)
    }
    try store.record(
      id, part: "judge", trigger: .arrival, at: now,
      outcome: DesignSceneFixtures.judged(proposals, rows: taken.count))
  }

  // MARK: - 起動

  /// 起動で保存済みの部品を番人へ載せ、過ぎていた回を走らせる。止めた自動化の部品は予定では走らない。
  func testLaunchSchedulesStoredAutomationsExceptPausedOnes() throws {
    let longAgo = Date().addingTimeInterval(-86400)
    let (active, paused) = try {
      let saved = AutomationStore()
      let active = try saved.create(Self.definition("動いている"), now: longAgo)
      let paused = try saved.create(Self.definition("止めた"), now: longAgo)
      _ = try saved.setPaused(paused.id, true, now: longAgo)
      return (active, paused)
    }()

    let wc = try launch()

    XCTAssertTrue(wc.automationRunner.isRunning(active.id), "過ぎていた回が起動で始まる")
    XCTAssertFalse(wc.automationRunner.isRunning(paused.id), "止めた自動化は予定では走らない")
    XCTAssertTrue(
      waitUntil(10) { wc.automationStore.automation(active.id)?.runs.isEmpty == false },
      "起動で始まった回が確定しない")
    XCTAssertEqual(wc.automationStore.automation(active.id)?.runs.first?.trigger, .schedule)
  }

  // MARK: - 棚と重なり

  /// 提案は棚に出す自動化の側に出て、重なりは両方の自動化に相手と件数で出る。提案した自動化の取得が出どころの項目を出さなく
  /// なると提案は下がる（同じリンクをほかの自動化が取っていても）。提案した自動化が判定の部品を外すと、出どころの項目が残る提案は
  /// まだ取っている自動化の棚へ移る。
  func testProposalsAndOverlapsAppearOnTheShelfAutomation() throws {
    let wc = try launch()
    let store = wc.automationStore
    let first = try set(wc, Self.definition("受信 1"))
    let second = try set(wc, Self.definition("受信 2"))
    let gone = Self.item("gone")
    let moved = Self.item("moved")
    try Self.round(store, first, fetched: [gone, moved], proposing: [gone, moved])
    try Self.round(store, second, fetched: [moved, gone])

    let candidates = try listed(wc).compactMapValues { $0["taskCandidates"] as? [String: Any] }
    XCTAssertEqual(candidates[first]?["openProposals"] as? Int, 2)
    XCTAssertEqual(candidates[second]?["openProposals"] as? Int, 0)
    for (id, other, name) in [(first, second, "受信 2"), (second, first, "受信 1")] {
      let overlaps = candidates[id]?["overlaps"] as? [[String: Any]]
      XCTAssertEqual(
        overlaps?.map { $0["automationId"] as? Int }, [other], "自動化 \(id) に相手が出る")
      XCTAssertEqual(overlaps?.first?["name"] as? String, name)
      XCTAssertEqual(overlaps?.first?["count"] as? Int, 2)
    }

    try Self.round(store, first, fetched: [moved])
    XCTAssertEqual(
      try proposals(wc, of: first).map { $0["link"] as? String }, [moved.link],
      "出どころの項目が消えた提案は下がる")
    XCTAssertTrue(try proposals(wc, of: second).isEmpty)

    var reporting = try XCTUnwrap(store.automation(first)?.definition)
    reporting.parts[1] = DesignSceneFixtures.commandPart(
      "digest", "要約", .arrival, from: ["fetch"], script: "digest", deliver: .report)
    _ = try success(
      wc.controlSetAutomation(
        automationId: first, version: store.automation(first)?.version, reporting))
    let shelved = try proposals(wc, of: second)
    XCTAssertEqual(shelved.map { $0["link"] as? String }, [moved.link], "取っている受信の棚へ")
    XCTAssertEqual(shelved.first?["automationId"] as? Int, second)
    XCTAssertEqual(shelved.first?["automationName"] as? String, "受信 2")
  }

  /// 候補を出した自動化と部品の鍵は組（`proposedBy`）で出し、棚の自動化と取り違えない。部品は今の鍵で言い、外した部品は出さない。
  /// 出した自動化を消すと、出どころの項目が無効になるので提案は下がる。
  func testProposedByNamesTheProposingAutomationApartFromTheShelf() throws {
    let wc = try launch()
    let store = wc.automationStore
    let first = try set(wc, Self.definition("受信 1"))
    let second = try set(wc, Self.definition("受信 2"))
    let moved = Self.item("moved")
    try Self.round(store, first, fetched: [moved], proposing: [moved])
    try Self.round(store, second, fetched: [moved])
    var reporting = try XCTUnwrap(store.automation(first)?.definition)
    reporting.parts[0].key = "source"
    reporting.parts[1] = DesignSceneFixtures.commandPart(
      "digest", "要約", .arrival, from: ["source"], script: "digest", deliver: .report)
    _ = try success(wc.controlSetAutomation(automationId: first, version: 1, reporting))

    let shelved = try XCTUnwrap(try proposals(wc, of: second).first)
    XCTAssertEqual(shelved["automationId"] as? Int, second)
    let proposedBy = try XCTUnwrap(shelved["proposedBy"] as? [String: Any])
    XCTAssertEqual(proposedBy["automationId"] as? Int, first)
    XCTAssertNil(proposedBy["partKey"], "外した判定の部品は言わない")
    XCTAssertEqual(proposedBy["sourcePartKey"] as? String, "source", "出どころの部品は今の鍵で言う")

    _ = wc.controlDeleteAutomation(automationId: first)
    XCTAssertTrue(try proposals(wc, of: second).isEmpty)
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

  /// 判定が書いた候補にした理由は、その候補にだけ `reason` として出る。
  func testProposalsCarryTheReasonOnlyWhenTheJudgeWroteOne() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition())
    let items = ["a", "b"].map { Self.item($0) }
    try Self.round(
      wc.automationStore, id, fetched: items, proposing: items,
      reasons: ["レビューを頼まれている。", nil])

    let listed = Dictionary(
      uniqueKeysWithValues: try proposals(wc, of: id).map { ($0["title"] as? String ?? "", $0) })

    XCTAssertEqual(listed["対応: a"]?["reason"] as? String, "レビューを頼まれている。")
    XCTAssertNotNil(listed["対応: b"], "前提")
    XCTAssertNil(listed["対応: b"]?["reason"], "書かなかった候補はキーごと出さない")
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
    if case .agent(var agent) = codex.parts[1].action.method {
      agent.cli = "codex"
      codex.parts[1].action.method = .agent(agent)
    }

    XCTAssertEqual(code(wc.controlRunAutomation(automationId: 99, partKey: nil)), -32004)
    XCTAssertEqual(code(wc.controlRunAutomation(automationId: id, partKey: "nope")), -32004)
    XCTAssertEqual(code(wc.controlPauseAutomation(automationId: 99, paused: true)), -32004)
    XCTAssertEqual(code(wc.controlDeleteAutomation(automationId: 99)), -32004)
    XCTAssertEqual(code(wc.controlListAutomationProposals(automationId: 99)), -32004)
    XCTAssertEqual(
      code(wc.controlSetAutomation(automationId: 99, version: 1, Self.definition())), -32004)
    XCTAssertEqual(code(wc.controlSetAutomation(automationId: id, version: 1, codex)), -32602)
    XCTAssertEqual(code(wc.controlSetAutomation(automationId: nil, version: nil, codex)), -32602)
    XCTAssertEqual(
      wc.automationStore.automations.map { $0.definition.parts.map(\.key) }, [["fetch", "judge"]])
    XCTAssertEqual(wc.automationStore.automations.map(\.version), [1])
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
    var stored = definition
    for index in stored.parts.indices {
      stored.parts[index].id = wc.automationStore.part(id, stored.parts[index].key)
    }

    XCTAssertEqual(
      try AutomationWire.decoder.decode(AutomationDefinition.self, from: data), stored)
  }

  /// 試走は始めた応答で道の上の部品を並べ、待って読むと部品の回の結果を返す。自動化を消すと読めない。
  func testATrialStartsAtOnceAndReadsBackItsPartsWhenWaitedFor() throws {
    let wc = try launch()
    let id = try set(
      wc,
      AutomationDefinition(
        name: "試す", notify: nil,
        parts: [
          DesignSceneFixtures.commandPart(
            "fetch", "取る", .manual, script: "exit 1", coverage: .currentSet),
          DesignSceneFixtures.commandPart(
            "send", "送る", .arrival, from: ["fetch"], script: "exit 1", deliver: .sideEffect),
        ]))
    let row = #"{"id":"a","link":"https://example.com/a","body":"a","time":"2026-10-10T09:00:00Z"}"#
    var none: Result<Any, ControlError>?
    wc.controlAutomationTrial(automationId: id, wait: false, timeoutMs: 1) { none = $0 }
    guard case .failure(let noTrial) = try XCTUnwrap(none) else { return XCTFail("試走が無いのに読めた") }
    XCTAssertEqual(noTrial.code, -32004)
    XCTAssertEqual(noTrial.message, "no trial of automation \(id)")

    let started = try success(
      wc.controlTryAutomation(automationId: id, AutomationTrial.Request(rows: [row])))
    let trial = try XCTUnwrap(started["trial"] as? [String: Any])
    XCTAssertEqual(trial["preparing"] as? Bool, true)
    XCTAssertEqual(
      (trial["parts"] as? [[String: Any]])?.map { $0["key"] as? String }, ["fetch", "send"])

    var reply: Result<Any, ControlError>?
    wc.controlAutomationTrial(automationId: id, wait: true, timeoutMs: 5000) { reply = $0 }
    let deadline = Date().addingTimeInterval(5)
    while reply == nil && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let read = try success(try XCTUnwrap(reply))
    XCTAssertNil(read["timedOut"])
    let ended = try XCTUnwrap(read["trial"] as? [String: Any])
    XCTAssertEqual(ended["running"] as? Bool, false)
    let parts = try XCTUnwrap(ended["parts"] as? [[String: Any]])
    XCTAssertEqual(parts.map { $0["state"] as? String }, ["given", "held"])
    let fetchId = "\(wc.automationStore.part(id, "fetch")):a"
    let given = try XCTUnwrap(
      (parts[0]["runs"] as? [[String: Any]])?.first?["given"] as? [String: Any])
    XCTAssertEqual((given["rows"] as? [[String: Any]])?.map { $0["id"] as? String }, [fetchId])
    let held = try XCTUnwrap(
      (parts[1]["runs"] as? [[String: Any]])?.first?["held"] as? [String: Any])
    XCTAssertEqual((held["rows"] as? [[String: Any]])?.map { $0["id"] as? String }, [fetchId])

    _ = wc.controlDeleteAutomation(automationId: id)
    var gone: Result<Any, ControlError>?
    wc.controlAutomationTrial(automationId: id, wait: false, timeoutMs: 1) { gone = $0 }
    XCTAssertEqual(code(try XCTUnwrap(gone)), -32004)
  }
}
