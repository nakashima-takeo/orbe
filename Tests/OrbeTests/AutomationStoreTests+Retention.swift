import XCTest

@testable import Orbe

/// 掃除——どこからも指されなくなった古い行を消し、指されている行は残す。
///
/// 壊れると何が起きるか: 期限を過ぎた出来事・置き換わった古い版・消した自動化の判断と記録が DB に溜まり続ける。消しすぎると、
/// 候補や回の記録が指す行が消える。
extension AutomationStoreTests {
  private static let day: TimeInterval = 86400

  /// 閉じた DB の `table` の、`condition` に合う行の数。
  private func count(_ table: String, where condition: String = "1") throws -> Int {
    try database().select("SELECT count(*) FROM \(table) WHERE \(condition)", []) {
      $0.int(at: 0)
    }.first ?? -1
  }

  /// 残す期間を過ぎた出来事は、どこからも指されていなければ消え、候補と回の履歴が指すものは残る。
  func testExpiredEventsAreSweptUnlessSomethingPointsAtThem() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(coverage: .newArrivals), now: Self.at).id)
    let a = Self.item("a")
    try Self.fetch(XCTUnwrap(store), id, [a])
    try Self.judge(XCTUnwrap(store), id, proposing: [a])
    try Self.fetch(XCTUnwrap(store), id, [Self.item("b")], at: Self.at.addingTimeInterval(60))
    try Self.fetch(
      XCTUnwrap(store), id, [Self.item("c")], at: Self.at.addingTimeInterval(31 * Self.day))
    store = nil

    XCTAssertEqual(try count("events", where: "written_id = 'a'"), 1, "候補と判定の回が指す")
    XCTAssertEqual(try count("events", where: "written_id = 'b'"), 0)
  }

  /// 今有効な項目の置き換わった古い版は、出す側の残っている回より前に置き換わり、どこからも指されていなければ消える。
  func testAReplacedVersionIsSweptOnceTheRunsBeforeItsReplacementAreGone() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    try Self.fetch(XCTUnwrap(store), id, [Self.item("a")])
    let changed = AutomationItem(
      id: "a", link: "https://example.com/a", body: "変わった本文", time: Self.at)
    for n in 1...(AutomationPartState.retainedRuns + 1) {
      try Self.fetch(
        XCTUnwrap(store), id, [changed], at: Self.at.addingTimeInterval(60 * Double(n)))
    }
    store = nil

    XCTAssertEqual(try count("item_versions"), 1)
    XCTAssertEqual(try count("item_versions", where: "body LIKE '%変わった本文%'"), 1, "今の版は残る")
  }

  /// 走っている回が読んだ行（出どころの版を含む）は、どこからも指されていなくても確定まで消さない。
  func testAVersionARunningPassHoldsIsNotSwept() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    try Self.fetch(XCTUnwrap(store), id, [Self.item("a")])
    let first = try XCTUnwrap(
      store?.read { try $0.db.select("SELECT min(id) FROM item_versions", []) { $0.int(at: 0) } }
        .first)
    store?.holding = { [.version(first)] }
    let changed = AutomationItem(
      id: "a", link: "https://example.com/a", body: "変わった本文", time: Self.at)
    for n in 1...(AutomationPartState.retainedRuns + 1) {
      try Self.fetch(
        XCTUnwrap(store), id, [changed], at: Self.at.addingTimeInterval(60 * Double(n)))
    }
    store = nil

    XCTAssertEqual(try count("item_versions", where: "id = \(first)"), 1)
  }

  /// 判断した候補を持つ自動化を消すと、その自動化の行（部品・つながり・定義・出した行・回・候補・判断）は 1 つも残らない。
  func testADeletedAutomationLeavesNoRowsBehind() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    try Self.fetch(XCTUnwrap(store), id, [Self.item("a")])
    try Self.judge(XCTUnwrap(store), id, proposing: [Self.item("a")])
    try store?.dismiss(XCTUnwrap(store?.proposals.first?.id), now: Self.at)

    try store?.delete(id, now: Self.at)
    store = nil

    for table in [
      "automations", "parts", "part_edges", "part_defs", "action_defs", "items", "item_versions",
      "events", "runs", "proposals", "held_proposals", "settlements",
    ] {
      XCTAssertEqual(try count(table), 0, table)
    }
  }
}
