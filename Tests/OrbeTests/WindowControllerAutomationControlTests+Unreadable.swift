import XCTest

@testable import Orbe

/// 定義を読めない自動化と、使えない DB の外の口。
///
/// 壊れると何が起きるか: 読めない自動化が一覧から消え、AI が直すことも消すこともできない。新しい版の DB で起動した Orbe の
/// 一覧が 0 件を返し、AI が自動化を作り直して二重に動かす。
extension WindowControllerAutomationControlTests {
  /// 読めない自動化は一覧の自分の場所に、行から組めた定義（部品の id つき）・版・理由で載り、回の記録は部品の鍵で読める。
  /// 一覧の id と版を添えた `set_automation` で、同じ部品のまま直る。
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
    let definition = try XCTUnwrap(entry["definition"] as? [String: Any])
    let parts = try XCTUnwrap(definition["parts"] as? [[String: Any]])
    XCTAssertEqual(parts.map { $0["key"] as? String }, ["fetch", "judge"])
    var fixed = Self.definition()
    for index in fixed.parts.indices {
      fixed.parts[index].id = (parts[index]["id"] as? Int).map(AutomationPartID.init)
    }
    let set = try success(wc.controlSetAutomation(automationId: 1, version: 1, fixed))
    XCTAssertEqual((set["automation"] as? [String: Any])?["version"] as? Int, 2)
    XCTAssertNil(try listed(wc)[1]?["definitionError"])
    XCTAssertEqual(
      wc.automationStore.automation(1)?.graph.nodes.map(\.id),
      fixed.parts.compactMap(\.id), "一覧の id で直すと同じ部品のまま")
  }

  /// 今より新しい版の DB では、一覧も書き換えも理由を言って断る。
  func testANewerDatabaseRefusesTheListWithTheReason() throws {
    _ = try AutomationStore().create(Self.definition(), now: Date())
    try SQLiteDatabase(url: automationsFolder().appendingPathComponent("db.sqlite")).exec(
      "PRAGMA user_version = 99")
    let wc = try launch()

    guard case .failure(let error) = wc.controlListAutomations() else {
      return XCTFail("一覧が断られない")
    }
    XCTAssertEqual(error.code, -32000)
    XCTAssertTrue(error.message.contains("version 99"), error.message)
  }
}
