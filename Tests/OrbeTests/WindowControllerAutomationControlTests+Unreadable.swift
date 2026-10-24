import XCTest

@testable import Orbe

/// 定義を読めない自動化と、使えない DB の外の口。
///
/// 壊れると何が起きるか: 読めない自動化が一覧から消え、AI が直すことも消すこともできない。新しい版の DB で起動した Orbe の
/// 一覧が 0 件を返し、AI が自動化を作り直して二重に動かす。ほかの動詞が「見つからない」と答え、AI が消えたと読み違える。
extension WindowControllerAutomationControlTests {
  /// 読めない自動化は一覧の自分の場所に、行から組めた定義（部品の id つき）・版・理由で載り、回の記録は部品の鍵で読める。
  /// 候補の一覧はほかの動詞と同じく読めない理由で断る。一覧の id と版を添えた `set_automation` で、同じ部品のまま直る。
  func testAnUnreadableAutomationIsListedWithItsReasonAndCanBeFixed() throws {
    try {
      let store = AutomationStore()
      let id = try store.create(Self.definition(), now: Date()).id
      try store.record(id, part: "fetch", at: Date(), outcome: DesignSceneFixtures.fetched([]))
      try store.read {
        try $0.db.run(
          """
          UPDATE action_defs SET action = '{"instruction": 1}'
          WHERE id = (SELECT def_id FROM parts WHERE automation_id = ? AND key = 'judge')
          """, [.integer(Int64(id))])
      }
    }()
    let wc = try launch()

    let entry = try XCTUnwrap(try listed(wc)[1])
    XCTAssertEqual(entry["version"] as? Int, 1)
    XCTAssertEqual(
      (entry["definitionError"] as? String)?.hasPrefix("invalid parts[1].instruction"), true)
    let runs = try success(
      wc.controlListAutomationRuns(automationId: 1, partKey: nil, before: nil, limit: nil))
    XCTAssertEqual(
      (runs["runs"] as? [[String: Any]])?.map { $0["partKey"] as? String },
      ["fetch"], "回の記録は部品の鍵で返る")
    guard case .failure(let refused) = wc.controlListAutomationProposals(automationId: 1) else {
      return XCTFail("読めない自動化の候補は断る")
    }
    XCTAssertEqual(refused.code, -32000, "見つからないではなく、読めない理由で断る")
    let definition = try XCTUnwrap(entry["definition"] as? [String: Any])
    let parts = try XCTUnwrap(definition["parts"] as? [[String: Any]])
    XCTAssertEqual(parts.map { $0["key"] as? String }, ["fetch", "judge"])
    var fixed = Self.definition()
    for index in fixed.parts.indices {
      fixed.parts[index].id = (parts[index]["id"] as? Int).map(AutomationNodeID.init)
    }
    let set = try success(wc.controlSetAutomation(automationId: 1, version: 1, fixed))
    XCTAssertEqual((set["automation"] as? [String: Any])?["version"] as? Int, 2)
    XCTAssertNil(try listed(wc)[1]?["definitionError"])
    XCTAssertEqual(
      wc.automationStore.automation(1)?.graph.nodes.map(\.id),
      fixed.parts.compactMap(\.id), "一覧の id で直すと同じ部品のまま")
  }

  /// 値の壊れた候補は、候補の一覧に分かる分（ID・リンク・`unreadable`）だけで載り、自動化で絞っても持ち主の自動化に載る。
  func testAProposalThatCannotBeReadIsListedWithWhatIsKnown() throws {
    try {
      let store = AutomationStore()
      let id = try store.create(Self.definition(), now: AutomationStoreTests.at).id
      let a = AutomationStoreTests.item("a")
      try AutomationStoreTests.fetch(store, id, [a])
      try AutomationStoreTests.judge(store, id, proposing: [a])
      try store.read { try $0.db.run("UPDATE proposals SET due = 'x'", []) }
    }()
    let wc = try launch()

    let proposals = try success(wc.controlListAutomationProposals(automationId: 1))["proposals"]
    let listed = try XCTUnwrap(proposals as? [[String: Any]])
    XCTAssertEqual(listed.count, 1)
    XCTAssertEqual(listed.first?.keys.sorted(), ["link", "proposalId", "unreadable"])
    XCTAssertEqual(listed.first?["link"] as? String, "https://example.com/a")
    XCTAssertEqual(listed.first?["unreadable"] as? Bool, true)
  }

  /// 今より新しい版の DB では、自動化のどの動詞も中身を見る前に、-32000 と理由で断る。
  func testANewerDatabaseRefusesEveryVerbWithTheReason() throws {
    _ = try AutomationStore().create(Self.definition(), now: Date())
    try SQLiteDatabase(url: automationsFolder().appendingPathComponent("db.sqlite")).exec(
      "PRAGMA user_version = 99")
    let wc = try launch()

    var answers: [String: Result<Any, ControlError>] = [
      "list_automations": wc.controlListAutomations(),
      "set_automation": wc.controlSetAutomation(automationId: nil, version: nil, Self.definition()),
      "list_automation_runs": wc.controlListAutomationRuns(
        automationId: 1, partKey: nil, before: nil, limit: nil),
      "run_automation": wc.controlRunAutomation(automationId: 1, partKey: nil),
      "pause_automation": wc.controlPauseAutomation(automationId: 1, paused: true),
      "delete_automation": wc.controlDeleteAutomation(automationId: 1),
      "list_automation_proposals": wc.controlListAutomationProposals(automationId: nil),
      "try_automation": wc.controlTryAutomation(automationId: 1, AutomationTrial.Request()),
    ]
    wc.controlAutomationTrial(automationId: 1, wait: false, timeoutMs: 0) {
      answers["get_automation_trial"] = $0
    }

    XCTAssertEqual(answers.count, 9)
    for (verb, answer) in answers {
      guard case .failure(let error) = answer else {
        XCTFail("\(verb) が断られない")
        continue
      }
      XCTAssertEqual(error.code, -32000, verb)
      XCTAssertTrue(error.message.contains("version 99"), "\(verb): \(error.message)")
    }
  }
}
