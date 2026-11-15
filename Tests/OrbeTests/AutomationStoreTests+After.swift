import XCTest

@testable import Orbe

/// つながりの読む行の下限の時刻（`after`）——今ある取得に足した受け手を「これから来る分だけ」にする読みと、書くときの確かめ。
///
/// 壊れると何が起きるか: 今ある取得に足した受け手に、足した時点の項目がすべて流れ込み、副作用や候補が一度に起きる。未来の時刻を
/// 書いた受け手が、その時刻までに来た行を黙って捨てる。
extension AutomationStoreTests {
  /// 取得 `fetch` を読む副作用の受け手 `key`。
  private func sideEffect(_ key: String, after: Date? = nil) -> AutomationDefinition.Node {
    var definitionNode = DesignSceneFixtures.commandNode(
      key, key, .arrival, from: ["fetch"], script: key, deliver: .sideEffect)
    definitionNode.from = [AutomationDefinition.Input(nodeKey: "fetch", after: after)]
    return definitionNode
  }

  /// 受け手 `key` の、読める行をすべて取る回を確定する。取った行の書かれた id を返す。
  @discardableResult private func receive(
    _ store: AutomationStore, _ id: Int, _ key: String, at: Date
  ) throws -> [String] {
    let nodeId = store.nodeId(id, key)
    let read = try XCTUnwrap(store.read(nodeId, of: id, baseline: nil, now: at))
    try store.record(
      AutomationPassEnd(
        automationId: id, nodeId: nodeId,
        defId: try XCTUnwrap(store.automation(id)?.graph.node(nodeId)).entity.defId,
        trigger: .arrival, startedAt: at, endedAt: at, read: read,
        outcome: DesignSceneFixtures.sideEffected(read.taken.count)))
    return read.taken.map { String($0.id.split(separator: ":", maxSplits: 1).last ?? "") }
  }

  /// 今の集合の取得に、読む行の下限の時刻に書いた時点を持たせた受け手を足すと、足した時点の今有効な項目は届かず（未処理も 0）、
  /// その項目は次の回の `dropped.expired` に数えられ、その後に有効になった項目だけが届く。前からの受け手の読みは変わらない。
  func testAReceiverAddedWithAfterGetsOnlyItemsThatBecomeCurrentLater() throws {
    let store = AutomationStore()
    let fetch = DesignSceneFixtures.commandNode(
      "fetch", "取る", .scheduled(.every(1800)), script: "fetch", coverage: .currentSet)
    var definition = AutomationDefinition(
      name: "受け手", notify: nil, nodes: [fetch, sideEffect("a")])
    let id = try store.create(definition, now: Self.at).id
    try Self.fetch(store, id, [Self.item("x"), Self.item("y")])
    try receive(store, id, "a", at: Self.at)
    let written = Self.at.addingTimeInterval(60)
    definition.nodes.append(sideEffect("late", after: written))
    try Self.rewrite(store, id, definition, at: written)
    XCTAssertEqual(store.automation(id)?.state(key: "late").pending.count, 0)

    let later = written.addingTimeInterval(1800)
    try Self.fetch(store, id, ["x", "y", "z"].map(Self.item), at: later)

    XCTAssertEqual(try receive(store, id, "a", at: later), ["z"])
    XCTAssertEqual(try receive(store, id, "late", at: later), ["z"])
    XCTAssertEqual(
      store.automation(id)?.state(key: "late").runs.first?.run?.dropped.counts, [.expired: 2])
  }

  /// 読む行の下限の時刻に、書く時点より後の時刻を書いた定義は、場所を示して断り、何も書かない。
  func testAnAfterLaterThanTheWriteIsRefusedWithItsPlace() {
    let store = AutomationStore()
    var definition = Self.definition()
    definition.nodes.append(sideEffect("late", after: Self.at.addingTimeInterval(1)))

    XCTAssertThrowsError(try store.create(definition, now: Self.at)) {
      XCTAssertEqual(
        $0 as? AutomationError,
        .invalid(
          "nodes[2].from[0].after: 2027-01-15T08:00:01.000Z is later than now "
            + "(2027-01-15T08:00:00.000Z); pass the current time or an earlier one"))
    }
    XCTAssertEqual(store.automations, [])
  }
}
