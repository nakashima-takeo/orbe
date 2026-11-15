import XCTest

@testable import Orbe

/// つながりの読む行の下限の時刻（`after`）——今ある取得に足した受け手を「これから来る分だけ」にする読みと、書くときの確かめ。
///
/// 壊れると何が起きるか: 今ある取得に足した受け手に、足した時点の項目がすべて流れ込み、副作用や候補が一度に起きる。未来の時刻を
/// 書いた受け手が、その時刻までに来た行を黙って捨てる。書き込みで足したノードから読むつながりに書いた下限の時刻が、黙って何も除か
/// ない。そのため、足した経路に今ある項目が流れ込む。
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
  func testAnAfterLaterThanTheWriteIsRefusedWithItsPlace() throws {
    let store = AutomationStore()
    var definition = Self.definition()
    let id = try store.create(definition, now: Self.at).id
    definition.nodes.append(sideEffect("late", after: Self.at.addingTimeInterval(1)))

    XCTAssertThrowsError(try Self.rewrite(store, id, definition)) {
      XCTAssertEqual(
        $0 as? AutomationError,
        .invalid(
          "nodes[2].from[0].after: 2027-01-15T08:00:01.000Z is later than now "
            + "(2027-01-15T08:00:00.000Z); pass the current time or an earlier one"))
    }
    XCTAssertEqual(store.automation(id)?.version, 1)
  }

  /// その書き込みで足すノードから読むつながりに、読む行の下限の時刻を書いた定義は、場所を示して断り、何も書かない（足すノード
  /// の行はどれも書き込みの後にできるので、何も除かない）。新しく作る自動化では、どのつながりにも下限の時刻を書けない。今あるノードから読む
  /// つながりの下限の時刻は書ける。
  func testAnAfterOnAnInputFromANodeTheWriteAddsIsRefusedWithItsPlace() throws {
    let store = AutomationStore()
    var definition = Self.definition()
    var created = definition
    created.nodes[1].from = [AutomationDefinition.Input(nodeKey: "fetch", after: Self.at)]
    XCTAssertThrowsError(try store.create(created, now: Self.at)) {
      XCTAssertEqual(
        $0 as? AutomationError,
        .invalid(
          "nodes[1].from[0].after: a new automation has no rows yet, so after drops nothing; "
            + "leave it out"))
    }
    XCTAssertEqual(store.automations, [])
    let id = try store.create(definition, now: Self.at).id
    var process = DesignSceneFixtures.commandNode("p", "要約", .arrival, script: "p")
    process.from = [AutomationDefinition.Input(nodeKey: "fetch", after: Self.at)]
    var late = DesignSceneFixtures.commandNode(
      "late", "late", .arrival, script: "late", deliver: .sideEffect)
    late.from = [AutomationDefinition.Input(nodeKey: "p", after: Self.at)]
    definition.nodes += [process, late]

    XCTAssertThrowsError(try Self.rewrite(store, id, definition)) {
      XCTAssertEqual(
        $0 as? AutomationError,
        .invalid(
          #"nodes[3].from[0].after: "p" is a node this write adds, so after drops nothing; "#
            + "write after on an input from a node that exists now"))
    }
    XCTAssertEqual(store.automation(id)?.version, 1)
    definition.nodes[3].from[0].after = nil
    XCTAssertThrowsError(try store.replace(id, version: 1, with: definition, now: Self.at)) {
      XCTAssertEqual(
        $0 as? AutomationError,
        .invalid(
          #"nodes[0].id: the key "fetch" belongs to node \#(store.nodeId(id, "fetch")); "#
            + "send its id to keep the node, or use another key for a new node"),
        "今あるノードの id を送らない定義は、下限の時刻より先に id の不備で断る")
    }
    XCTAssertNoThrow(try Self.rewrite(store, id, definition))
  }
}
