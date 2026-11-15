import XCTest

@testable import Orbe

/// 1 つの判定に入力を集めた形の候補の下げ方——候補の元の行が今のものでなくなっても、判定のほかの入力に同じリンクの今の行が
/// 残る間は下げず、無くなった最初の変異で下げる。
///
/// 壊れると何が起きるか: 片方の取得が外した・出来事が残す期間を過ぎただけで、まだある項目の候補が消えて戻らない。支えていた入力を
/// 外す・支えていた出来事が残す期間を過ぎる・支えていた出来事の元の項目が消える、のどれでも下がらず、候補が棚に残り続ける。
extension AutomationStoreTests {
  /// 取得 f1・f2（それぞれ `f1`・`f2` の出力の性質）→ 判定 の自動化の定義。`judgeFrom` は判定の入力。
  private func gathering(
    judgeFrom inputs: [String] = ["f1", "f2"], f1: AutomationCoverage = .currentSet,
    f2: AutomationCoverage = .currentSet
  ) -> AutomationDefinition {
    let fetch = { (key: String, coverage: AutomationCoverage) in
      DesignSceneFixtures.commandNode(
        key, key, .scheduled(.every(1800)), script: key, coverage: coverage)
    }
    return AutomationDefinition(
      name: "集める", notify: nil,
      nodes: [
        fetch("f1", f1), fetch("f2", f2),
        DesignSceneFixtures.agentNode(
          "judge", "判定", .arrival, from: inputs, instruction: "選ぶ", deliver: .taskCandidates),
      ])
  }

  /// `gathering` の自動化で、f1・f2 が同じリンクの項目を出し、判定が f1 の行から候補にし、f1 が項目を外した状態（f2 が支えて
  /// 候補は残る）。自動化の ID を返す。
  private func supportedByF2(_ store: AutomationStore) throws -> Int {
    let id = try store.create(gathering(), now: Self.at).id
    let a = Self.item("a")
    for key in ["f1", "f2"] {
      try store.record(id, nodeKey: key, at: Self.at, outcome: DesignSceneFixtures.fetched([a]))
    }
    try Self.judge(store, id, proposing: [a])
    XCTAssertEqual(store.proposals.map(\.originNodeId), [store.nodeId(id, "f1")])
    try store.record(id, nodeKey: "f1", at: Self.at, outcome: DesignSceneFixtures.fetched([]))
    XCTAssertEqual(store.proposals.map(\.state), [.open], "前提: f2 にまだあるので残る")
    return id
  }

  /// 1 つの判定に 2 つの取得（どちらも今の集合）から同じリンクが届くとき、候補の元の取得が外しても、もう片方にあれば残る。もう
  /// 片方も外すと下がり、その取得の回に数える。
  func testAProposalStaysWhileAnotherInputOfTheJudgeStillHasItsLink() throws {
    let store = AutomationStore()
    let id = try supportedByF2(store)

    try store.record(id, nodeKey: "f2", at: Self.at, outcome: DesignSceneFixtures.fetched([]))
    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(store.automation(id)?.state(key: "f2").runs.first?.run?.withdrawn, 1)
  }

  /// 支えていた入力のノードを書き換えで外すと、判定の入力が変わるので、その場で下げる条件を当て直して下げる。
  func testRemovingTheInputThatStillHadTheLinkWithdrawsTheProposal() throws {
    let store = AutomationStore()
    let id = try supportedByF2(store)
    var definition = gathering(judgeFrom: ["f1"])
    definition.nodes.remove(at: 1)

    try Self.rewrite(store, id, definition)

    XCTAssertEqual(store.proposals, [])
  }

  /// 支えていた入力とのつながりだけを外しても、判定の入力が変わるので、その場で下げる。
  func testCuttingTheEdgeFromTheInputThatStillHadTheLinkWithdrawsTheProposal() throws {
    let store = AutomationStore()
    let id = try supportedByF2(store)
    var definition = gathering(judgeFrom: ["f1"])
    definition.nodes.append(
      DesignSceneFixtures.commandNode(
        "digest", "要約", .arrival, from: ["f2"], script: "digest", deliver: .report))

    try Self.rewrite(store, id, definition)

    XCTAssertEqual(store.proposals, [])
  }

  /// 支えていた入力の項目が無効にならず、新しい版でリンクだけを変えたときも、そのリンクが入力の今有効な項目から抜けたので下げ、
  /// その取得の回に数える。
  func testAnInputItemChangingItsLinkWithdrawsTheProposalItSupported() throws {
    let store = AutomationStore()
    let id = try supportedByF2(store)
    let moved = AutomationItem(id: "a", link: Self.link("moved"), body: "a の本文", time: Self.at)

    try store.record(
      id, nodeKey: "f2", at: Self.at.addingTimeInterval(60),
      outcome: DesignSceneFixtures.fetched([moved]))

    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(store.automation(id)?.state(key: "f2").runs.first?.run?.withdrawn, 1)
  }

  /// 判定が読んだ出来事が残す期間を過ぎても、判定のもう 1 つの入力の今有効な項目にリンクがあれば下げない。その入力も外すと下がる。
  func testAnExpiredEventKeepsItsProposalWhileAnotherInputOfTheJudgeStillHasItsLink() throws {
    let store = AutomationStore()
    let id = try store.create(gathering(f1: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    for key in ["f1", "f2"] {
      try store.record(id, nodeKey: key, at: Self.at, outcome: DesignSceneFixtures.fetched([a]))
    }
    try Self.judge(store, id, proposing: [a])
    XCTAssertEqual(store.proposals.map(\.originNodeId), [store.nodeId(id, "f1")], "前提: 出来事の行の候補")
    let later = Self.at.addingTimeInterval(Self.eventRetention + 60)

    try store.record(id, nodeKey: "f1", at: later, outcome: DesignSceneFixtures.fetched([]))
    XCTAssertEqual(store.proposals.map(\.state), [.open], "f2 にまだあるので残る")

    try store.record(id, nodeKey: "f2", at: later, outcome: DesignSceneFixtures.fetched([]))
    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(
      [
        store.automation(id)?.state(key: "f2").runs.first?.run?.withdrawn,
        try store.carried(id, "judge").withdrawn,
      ],
      [1, 0], "リンクを外した回に数え、判定の持ち越しには載せない")
  }

  /// 今の集合の取得 f1 の項目の候補を、出来事の流れの取得 f2 の同じリンクの出来事が支えている間は、f1 が外しても残す。その出来事が
  /// 残す期間を過ぎた後の最初の変異で下げ、判定の次の成功した回に数える。
  func testAProposalSupportedOnlyByAnEventIsWithdrawnByTheFirstMutationAfterTheEventExpires() throws
  {
    let store = AutomationStore()
    let id = try store.create(gathering(f2: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    for key in ["f1", "f2"] {
      try store.record(id, nodeKey: key, at: Self.at, outcome: DesignSceneFixtures.fetched([a]))
    }
    try Self.judge(store, id, proposing: [a])
    XCTAssertEqual(store.proposals.map(\.originNodeId), [store.nodeId(id, "f1")], "前提: 項目の行の候補")
    try store.record(id, nodeKey: "f1", at: Self.at, outcome: DesignSceneFixtures.fetched([]))
    XCTAssertEqual(store.proposals.map(\.state), [.open], "f2 の出来事が支えるので残る")
    let later = Self.at.addingTimeInterval(Self.eventRetention + 60)

    try store.record(id, nodeKey: "f1", at: later, outcome: DesignSceneFixtures.fetched([]))

    XCTAssertEqual(store.proposals, [])
    try Self.judge(store, id, at: later)
    XCTAssertEqual(store.automation(id)?.state(key: "judge").runs.first?.run?.withdrawn, 1)
  }

  /// 今の集合の取得 f1 の項目の候補を、別の取得 f2 の項目を処理が引き継いだ出来事が支えている間は、f1 が外しても残す。f2 が元の
  /// 項目を外すと支えが無くなるので下げ、f2 のその回に数える。
  func testAProposalSupportedByAProcessedEventIsWithdrawnWhenItsSourceItemLeaves() throws {
    let store = AutomationStore()
    var definition = gathering(judgeFrom: ["f1", "p"])
    definition.nodes.insert(
      DesignSceneFixtures.commandNode("p", "要約", .arrival, from: ["f2"], script: "p"), at: 2)
    let id = try store.create(definition, now: Self.at).id
    let a = Self.item("a")
    try store.record(id, nodeKey: "f1", at: Self.at, outcome: DesignSceneFixtures.fetched([a]))
    try store.record(id, nodeKey: "f2", at: Self.at, outcome: DesignSceneFixtures.fetched([a]))
    let input = try XCTUnwrap(
      store.read(store.nodeId(id, "p"), of: id, baseline: nil, now: Self.at)?.taken.first)
    try store.record(
      id, nodeKey: "p", at: Self.at,
      outcome: DesignSceneFixtures.processed(
        [AutomationNodeRow(id: input.id, text: input.text, ref: nil, source: input.source)], read: 1
      ))
    try Self.judge(store, id, proposing: [a])
    XCTAssertEqual(store.proposals.map(\.originNodeId), [store.nodeId(id, "f1")], "前提: f1 の項目の候補")
    try store.record(id, nodeKey: "f1", at: Self.at, outcome: DesignSceneFixtures.fetched([]))
    XCTAssertEqual(store.proposals.map(\.state), [.open], "処理の出来事が支えるので残る")

    try store.record(id, nodeKey: "f2", at: Self.at, outcome: DesignSceneFixtures.fetched([]))

    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(store.automation(id)?.state(key: "f2").runs.first?.run?.withdrawn, 1)
  }
}
