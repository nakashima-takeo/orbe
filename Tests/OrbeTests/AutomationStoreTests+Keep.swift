import XCTest

@testable import Orbe

/// 判定ごとの候補の保ち方——判定の `keep`、判定の入力に残るリンクの歯止め、処理が作った行の下げ方、毎回すべてを読む判定の覚え方。
///
/// 壊れると何が起きるか: 判定に片付けさせたい候補が、元の項目が消えたときに黙って消える。1 つの判定に入力を集めた形で、片方の
/// 取得が外しただけで、まだある項目の候補が消えて戻らない。処理がまとめた行の候補が、処理が外しても棚に残り続ける。直近の窓を
/// 毎回読む判定で、さばいた候補が次の回に戻る。
extension AutomationStoreTests {
  private func keeping(_ keep: AutomationKeep?) -> AutomationDefinition {
    var definition = Self.definition()
    definition.nodes[1].action.keep = keep
    return definition
  }

  /// `untilDecided` の判定の候補は、元の項目が無効になっても判断待ちのまま残る。`whileCurrent` へ書き換えると、元の項目が既に
  /// 無効の判断待ちがその場で下がる。
  func testUntilDecidedKeepsAProposalUntilItIsRewrittenToWhileCurrent() throws {
    let store = AutomationStore()
    let id = try store.create(keeping(.untilDecided), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])

    try Self.fetch(store, id, [])
    XCTAssertEqual(store.proposals.map(\.state), [.open])
    XCTAssertEqual(store.automation(id)?.state(key: "fetch").runs.first?.run?.withdrawn, 0)

    try Self.rewrite(store, id, keeping(nil))
    XCTAssertEqual(store.proposals, [])
  }

  /// 1 つの判定に 2 つの取得（どちらも今の集合）から同じリンクが届くとき、候補の元の取得が外しても、もう片方にあれば残る。もう
  /// 片方も外すと下がり、その取得の回に数える。
  func testAProposalStaysWhileAnotherInputOfTheJudgeStillHasItsLink() throws {
    let store = AutomationStore()
    let fetch = { (key: String) in
      DesignSceneFixtures.commandNode(
        key, key, .scheduled(.every(1800)), script: key, coverage: .currentSet)
    }
    let id = try store.create(
      AutomationDefinition(
        name: "集める", notify: nil,
        nodes: [
          fetch("f1"), fetch("f2"),
          DesignSceneFixtures.agentNode(
            "judge", "判定", .arrival, from: ["f1", "f2"], instruction: "選ぶ",
            deliver: .taskCandidates),
        ]), now: Self.at
    ).id
    let a = Self.item("a")
    for key in ["f1", "f2"] {
      try store.record(id, nodeKey: key, at: Self.at, outcome: DesignSceneFixtures.fetched([a]))
    }
    try Self.judge(store, id, proposing: [a])
    XCTAssertEqual(store.proposals.map(\.originNodeId), [store.nodeId(id, "f1")])

    try store.record(id, nodeKey: "f1", at: Self.at, outcome: DesignSceneFixtures.fetched([]))
    XCTAssertEqual(store.proposals.map(\.state), [.open])

    try store.record(id, nodeKey: "f2", at: Self.at, outcome: DesignSceneFixtures.fetched([]))
    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(store.automation(id)?.state(key: "f2").runs.first?.run?.withdrawn, 1)
  }

  /// 今の集合の処理が新しい id で作った行も候補になり、本文はその行のもの、出どころのノードはその処理。処理がその行を出さなく
  /// なると下がり、その処理の回に数える。
  func testAProposalOfARowAProcessMadeIsWithdrawnWhenTheProcessDropsIt() throws {
    let store = AutomationStore()
    var process = DesignSceneFixtures.commandNode(
      "p", "まとめ", .arrival, from: ["fetch"], script: "p", coverage: .currentSet)
    process.from = [AutomationDefinition.Input(nodeKey: "fetch", take: .all)]
    var definition = Self.definition()
    definition.nodes[1].from = [AutomationDefinition.Input(nodeKey: "p")]
    definition.nodes.insert(process, at: 1)
    let id = try store.create(definition, now: Self.at).id
    try Self.fetch(store, id, [Self.item("a")])
    let thread = AutomationNodeRow(
      id: "t1", text: #"{"id":"t1","link":"https://example.com/t1","body":"まとめた本文"}"#, ref: nil,
      source: nil)
    try store.record(
      id, nodeKey: "p", at: Self.at, outcome: DesignSceneFixtures.processed([thread], read: 1))
    try Self.judge(
      store, id, proposing: [AutomationItem(id: "t1", link: Self.link("t1"), body: "", time: nil)])

    let proposal = try XCTUnwrap(store.proposals.first)
    XCTAssertEqual(proposal.fields.body, "まとめた本文")
    XCTAssertNil(proposal.fields.time)
    XCTAssertEqual(proposal.originNodeId, store.nodeId(id, "p"))

    try store.record(
      id, nodeKey: "p", at: Self.at, outcome: DesignSceneFixtures.processed([], read: 1))
    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(store.automation(id)?.state(key: "p").runs.first?.run?.withdrawn, 1)
  }

  /// 出来事を毎回すべて読む判定は、さばいた候補のリンクを窓の内にある間は覚え、その出来事を判定の前で捨てる。窓を外れたら忘れる。
  func testAJudgeReadingAWindowEveryRunRemembersClosedProposalsWhileTheyAreInIt() throws {
    let store = AutomationStore()
    var definition = Self.definition(coverage: .newArrivals)
    definition.nodes[1].from = [
      AutomationDefinition.Input(nodeKey: "fetch", take: .all, maxAgeHours: 24)
    ]
    let id = try store.create(definition, now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    try store.dismiss(try XCTUnwrap(store.proposals.first).id, now: Self.at)

    XCTAssertEqual(store.proposals.map(\.state), [.dismissed])
    let judge = store.nodeId(id, "judge")
    let read = try XCTUnwrap(store.read(judge, of: id, baseline: nil, now: Self.at))
    XCTAssertEqual(read.taken, [])
    XCTAssertEqual(store.automation(id)?.state(key: "judge").pending.count, 0)

    try Self.fetch(store, id, [], at: Self.at.addingTimeInterval(25 * 3600))
    XCTAssertEqual(store.proposals, [])
  }
}
