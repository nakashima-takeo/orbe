import XCTest

@testable import Orbe

/// 読めば取る行の数の数え直し——確定が無くても、数えた行が古さの上限か出来事の残す期間を過ぎれば数えなくなる。
///
/// 壊れると何が起きるか: 次の確定が来るまで、ボードの未処理と `list_automations` の `pending` が、もう読まれない行を数え続ける。
extension AutomationStoreTests {
  /// 読めば取る行の数は、確定が無くても、数えた行が古さの上限か出来事の残す期間（30 日）を過ぎた後の数え直しで減る。次に
  /// 数え直す時刻は、どの受け手でもいちばん早く過ぎる時刻。
  func testPendingRowsAreRecountedOnceTheyPassTheAgeLimitOrTheEventRetention() throws {
    let store = AutomationStore()
    var aged = DesignSceneFixtures.commandNode(
      "a", "a", .arrival, from: ["fetch"], script: "a", deliver: .sideEffect)
    aged.from = [AutomationDefinition.Input(nodeKey: "fetch", maxAgeHours: 1)]
    let id = try store.create(
      AutomationDefinition(
        name: "受け手", notify: nil,
        nodes: [
          DesignSceneFixtures.commandNode(
            "fetch", "取る", .scheduled(.every(1800)), script: "fetch", coverage: .newArrivals),
          aged,
          DesignSceneFixtures.commandNode(
            "b", "b", .arrival, from: ["fetch"], script: "b", deliver: .sideEffect),
        ]), now: Self.at
    ).id
    try Self.fetch(store, id, [Self.item("x")])
    func pending(_ key: String) -> Int? { store.automation(id)?.state(key: key).pending.count }
    let day: TimeInterval = 86400
    XCTAssertEqual([pending("a"), pending("b")], [1, 1])
    XCTAssertEqual(store.nextPendingExpiry, Self.at.addingTimeInterval(3600))

    try store.recountExpired(now: Self.at.addingTimeInterval(7200))
    XCTAssertEqual([pending("a"), pending("b")], [0, 1])
    XCTAssertEqual(store.nextPendingExpiry, Self.at.addingTimeInterval(30 * day))

    try store.recountExpired(now: Self.at.addingTimeInterval(31 * day))
    XCTAssertEqual([pending("a"), pending("b")], [0, 0])
    XCTAssertNil(store.nextPendingExpiry)
  }
}
