import XCTest

@testable import Orbe

/// 読めば取る行の数の数え直し——確定が無くても、数えた行が古さの上限か出来事の残す期間を過ぎれば数えなくなる。
///
/// 壊れると何が起きるか: 次の確定が来るまで、ボードの未処理と `list_automations` の `pending` が、もう読まれない行を数え続ける。
extension AutomationStoreTests {
  /// 読めば取る行の数は、確定が無くても、数えた行が、古さの上限か出す側のノードの出来事の残す期間のうち早く過ぎる方を過ぎた
  /// 後に数え直すと減る。次に数え直す時刻は、全受け手のうちでいちばん早く過ぎる時刻。
  func testPendingRowsAreRecountedOnceTheyPassTheAgeLimitOrTheEventRetention() throws {
    let store = AutomationStore()
    var source = DesignSceneFixtures.commandNode(
      "fetch", "取る", .scheduled(.every(1800)), script: "fetch", coverage: .newArrivals)
    source.retentionDays = 10
    func receiver(_ key: String, maxAgeHours: Int) -> AutomationDefinition.Node {
      var node = DesignSceneFixtures.commandNode(
        key, key, .arrival, from: ["fetch"], script: key, deliver: .sideEffect)
      node.from = [AutomationDefinition.Input(nodeKey: "fetch", maxAgeHours: maxAgeHours)]
      return node
    }
    let day: TimeInterval = 86400
    let id = try store.create(
      AutomationDefinition(
        name: "受け手", notify: nil,
        nodes: [source, receiver("a", maxAgeHours: 1), receiver("b", maxAgeHours: 24 * 20)]),
      now: Self.at
    ).id
    try Self.fetch(store, id, [Self.item("x")])
    func pending(_ key: String) -> Int? { store.automation(id)?.state(key: key).pending.count }
    XCTAssertEqual([pending("a"), pending("b")], [1, 1])
    XCTAssertEqual(store.nextPendingExpiry, Self.at.addingTimeInterval(3600))

    try store.recountExpired(now: Self.at.addingTimeInterval(7200))
    XCTAssertEqual([pending("a"), pending("b")], [0, 1])
    XCTAssertEqual(
      store.nextPendingExpiry, Self.at.addingTimeInterval(10 * day), "古さの上限の 20 日より早い残す期間")

    try store.recountExpired(now: Self.at.addingTimeInterval(11 * day))
    XCTAssertEqual([pending("a"), pending("b")], [0, 0])
    XCTAssertNil(store.nextPendingExpiry)
  }
}
