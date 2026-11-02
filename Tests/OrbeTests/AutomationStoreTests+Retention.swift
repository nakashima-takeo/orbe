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
    for n in 1...(AutomationRetention.standard.runCount + 1) {
      try Self.fetch(
        XCTUnwrap(store), id, [changed], at: Self.at.addingTimeInterval(Self.day * Double(n)))
    }
    store = nil

    XCTAssertEqual(try count("item_versions"), 1)
    XCTAssertEqual(try count("item_versions", where: "body LIKE '%変わった本文%'"), 1, "今の版は残る")
  }

  /// 取得のノードが一度決まりを外して印の回が残す数を過ぎても残っていても、その後に置き換わった古い版は、残す数の内の回より
  /// 前に置き換わっていれば消える。
  func testAReplacedVersionIsSweptEvenWhileABreachRunOutlivesTheWindow() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    try Self.fetch(XCTUnwrap(store), id, [], outcome: Self.breached([Self.item("a")]))
    let changed = AutomationItem(
      id: "a", link: "https://example.com/a", body: "変わった本文", time: Self.at)
    for n in 1...(AutomationRetention.standard.runCount + 1) {
      try Self.fetch(
        XCTUnwrap(store), id, [changed], at: Self.at.addingTimeInterval(Self.day * Double(n)))
    }
    XCTAssertNotNil(store?.automation(id)?.state(key: "fetch").breach, "前提: 印の回が残る")
    store = nil

    XCTAssertEqual(try count("item_versions"), 1)
  }

  /// 走っている回が読んだ行（出どころの版を含む）は、どこからも指されていなくても確定まで消さない。
  func testAVersionARunningPassHoldsIsNotSwept() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    try Self.fetch(XCTUnwrap(store), id, [Self.item("a")])
    let first = try XCTUnwrap(
      store?.read { try $0.db.select("SELECT min(id) FROM item_versions", []) { $0.int(at: 0) } }
        .first)
    store?.holding = { AutomationHolding(rows: [.version(first)]) }
    let changed = AutomationItem(
      id: "a", link: "https://example.com/a", body: "変わった本文", time: Self.at)
    for n in 1...(AutomationRetention.standard.runCount + 1) {
      try Self.fetch(
        XCTUnwrap(store), id, [changed], at: Self.at.addingTimeInterval(Self.day * Double(n)))
    }
    store = nil

    XCTAssertEqual(try count("item_versions", where: "id = \(first)"), 1)
  }

  /// 判断した候補を持つ自動化を消すと、その自動化の行（ノード・つながり・定義・出した行・回・候補・判断）は 1 つも残らない。
  func testADeletedAutomationLeavesNoRowsBehind() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    try Self.fetch(XCTUnwrap(store), id, [Self.item("a")])
    try Self.judge(XCTUnwrap(store), id, proposing: [Self.item("a")])
    try store?.dismiss(XCTUnwrap(store?.proposals.first?.id), now: Self.at)

    try store?.delete(id, now: Self.at)
    store = nil

    for table in [
      "automations", "nodes", "node_edges", "node_defs", "action_defs", "items", "item_versions",
      "events", "runs", "proposals", "held_proposals", "settlements",
    ] {
      XCTAssertEqual(try count(table), 0, table)
    }
  }

  /// 回の記録は「新しい方から回数の内」か「期間の内」のどちらかに入れば残り、値は確定のたびに今の保持の値を読む。
  func testRunsAreKeptWithinTheCountOrTheDaysOfTheCurrentRetention() throws {
    var retention = AutomationRetention(runCount: 2, runDays: 3, eventDays: 30)
    var store: AutomationStore? = AutomationStore(
      opening: AutomationPersistence.open(retention: { retention }))
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    func fetch(onDay day: Int) throws {
      try Self.fetch(
        XCTUnwrap(store), id, [], outcome: DesignSceneFixtures.failed("boom"),
        at: Self.at.addingTimeInterval(Self.day * Double(day)))
    }
    func days() throws -> [Int] {
      try XCTUnwrap(store).read { db in
        try db.db.select(
          """
          SELECT r.started_at FROM runs r JOIN nodes n ON n.id = r.node_id WHERE n.key = 'fetch'
          ORDER BY r.id
          """, []
        ) {
          Int((AutomationPersistence.date($0.int64(at: 0)).timeIntervalSince(Self.at) / Self.day))
        }
      }
    }
    for day in 0...9 { try fetch(onDay: day) }
    XCTAssertEqual(try days(), [6, 7, 8, 9], "3 日以内の回は回数を超えても残る")

    retention.runDays = 1
    try fetch(onDay: 10)
    XCTAssertEqual(try days(), [9, 10], "変えた値は次の確定から効く")
    store = nil
  }

  /// 人の判断の記録も、判定のノードごとに「新しい方から回数の内」か「判断の時刻が期間の内」のどちらかに入れば残る。
  func testDecisionsAreKeptWithinTheCountOrTheDaysOfTheRetention() throws {
    var store: AutomationStore? = AutomationStore(
      opening: AutomationPersistence.open(retention: {
        AutomationRetention(runCount: 2, runDays: 3, eventDays: 30)
      }))
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    for day in [0, 5, 6, 7] {
      let at = Self.at.addingTimeInterval(Self.day * Double(day))
      let item = Self.item("i\(day)")
      try Self.fetch(XCTUnwrap(store), id, [item], at: at)
      try Self.judge(XCTUnwrap(store), id, proposing: [item], at: at)
      try store?.dismiss(XCTUnwrap(store?.proposals.first?.id), now: at)
      try Self.fetch(XCTUnwrap(store), id, [], at: at)
    }
    store = nil

    let decided = try database().select(
      "SELECT decided_at FROM settlements ORDER BY decided_at", []
    ) { Int((AutomationPersistence.date($0.int64(at: 0)).timeIntervalSince(Self.at) / Self.day)) }
    XCTAssertEqual(decided, [5, 6, 7], "3 日以内の判断は回数を超えても残る")
  }

  /// 出来事の流れのノードの `retentionDays` は、同じ id を同じ出来事とみなす窓を延ばす。書かないノードは全体の設定の日数。
  func testANodesRetentionDaysWidensTheWindowOfTheSameEvent() throws {
    let store = AutomationStore()
    var long = Self.definition(coverage: .newArrivals)
    long.nodes[0].retentionDays = 60
    let kept = try store.create(long, now: Self.at).id
    let plain = try store.create(Self.definition("既定", coverage: .newArrivals), now: Self.at).id
    let later = Self.at.addingTimeInterval(40 * Self.day)
    for id in [kept, plain] {
      try Self.fetch(store, id, [Self.item("a")])
      try Self.fetch(store, id, [Self.item("a")], at: later)
    }

    XCTAssertEqual(
      store.automation(kept)?.state(key: "fetch").runs.first?.run?.result,
      .fetch(fresh: 0, duplicates: 1), "60 日の内なので同じ出来事")
    XCTAssertEqual(
      store.automation(plain)?.state(key: "fetch").runs.first?.run?.result,
      .fetch(fresh: 1, duplicates: 0), "既定の 30 日を過ぎたので新しい出来事")
  }

  /// 出す側のノードの `retentionDays` の内の出来事は、全体の既定（30 日）を過ぎても掃除されず、受け手が読む。
  func testANodesRetentionDaysKeepsItsEventsForTheReceiverPastTheDefault() throws {
    let store = AutomationStore()
    var definition = Self.definition(coverage: .newArrivals)
    definition.nodes[0].retentionDays = 60
    let id = try store.create(definition, now: Self.at).id
    try Self.fetch(store, id, [Self.item("old")])
    let later = Self.at.addingTimeInterval(40 * Self.day)
    try Self.fetch(store, id, [Self.item("new")], at: later)

    let read = try XCTUnwrap(
      store.read(store.nodeId(id, "judge"), of: id, baseline: nil, now: later))
    XCTAssertEqual(
      read.taken.map(\.id), ["old", "new"].map { "\(store.nodeId(id, "fetch")):\($0)" })
  }

  /// 今の集合の古い版の掃除の基準は、回数の内か期間の内で残る回のうち最も古い始まり（期間の内で残る回が読みうる版を残す）。
  func testAReplacedVersionStaysWhileARunWithinTheDaysCouldHaveReadIt() throws {
    let retention = AutomationRetention(runCount: 1, runDays: 2, eventDays: 30)
    var store: AutomationStore? = AutomationStore(
      opening: AutomationPersistence.open(retention: { retention }))
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    func fetch(_ body: String, onDay day: Int) throws {
      try Self.fetch(
        XCTUnwrap(store), id,
        [AutomationItem(id: "a", link: "https://example.com/a", body: body, time: Self.at)],
        at: Self.at.addingTimeInterval(Self.day * Double(day)))
    }
    func versions() throws -> Int {
      try XCTUnwrap(store).read {
        try $0.db.select("SELECT count(*) FROM item_versions", []) { $0.int(at: 0) }
      }
      .first ?? -1
    }
    for day in 0...3 { try fetch("v\(day)", onDay: day) }
    XCTAssertEqual(try versions(), 4, "2 日以内に始まった回が読みうる版は残る")

    try fetch("v5", onDay: 5)
    XCTAssertEqual(try versions(), 3, "残る回より前に置き換わった版は消える")
    store = nil
  }

  /// 全体の設定の出来事の日数が、出す側のノードが日数を書かないときの見分けの窓になる。
  func testTheEventDaysSettingIsTheWindowOfANodeWithoutItsOwnDays() throws {
    let store = AutomationStore(
      opening: AutomationPersistence.open(retention: {
        AutomationRetention(runCount: 20, runDays: 7, eventDays: 10)
      }))
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    try Self.fetch(store, id, [Self.item("a")])
    try Self.fetch(store, id, [Self.item("a")], at: Self.at.addingTimeInterval(11 * Self.day))

    XCTAssertEqual(
      store.automation(id)?.state(key: "fetch").runs.first?.run?.result,
      .fetch(fresh: 1, duplicates: 0), "10 日を過ぎたので新しい出来事")
  }

  /// 保持の回数がメモリの直近の数より小さくても、メモリの直近の回は掃除の後の DB と同じ（消えた回を画面に残さない）。
  func testTheRecentRunsInMemoryFollowTheSweep() throws {
    let store = AutomationStore(
      opening: AutomationPersistence.open(retention: {
        AutomationRetention(runCount: 2, runDays: 1, eventDays: 30)
      }))
    let id = try store.create(Self.definition(), now: Self.at).id
    for day in 0...4 {
      try Self.fetch(
        store, id, [], outcome: DesignSceneFixtures.failed("boom"),
        at: Self.at.addingTimeInterval(Self.day * Double(day)))
    }

    XCTAssertEqual(
      store.automation(id)?.state(key: "fetch").runs.map(\.startedAt),
      [4, 3].map { Self.at.addingTimeInterval(Self.day * Double($0)) })
  }
}
