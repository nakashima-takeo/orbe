import XCTest

@testable import Orbe

/// 判定ごとの候補の保ち方——判定の入力に残るリンクの歯止め、処理を通った行の下げ方、毎回すべてを読む判定の覚え方。
///
/// 壊れると何が起きるか: 1 つの判定に入力を集めた形で、片方の取得が外した・出来事が残す期間を過ぎただけで、まだある項目の
/// 候補が消えて戻らない。取得 → 処理 → 判定 の形で、取得が外した項目の候補が棚に残り続ける。処理がまとめた行の候補が、処理が
/// 外しても棚に残り続ける。処理がまとめた行を書き換えるたびに、さばいた候補が戻る。直近の窓を毎回読む判定で、さばいた候補が次の回に戻る。
/// 取得（今の集合）→ 処理（出来事）→ 判定 で、取得にまだある課題の候補が出来事の残す期間で消える。同じリンクの出来事が続けて届く
/// 取得で、最初の出来事の残す期間で候補が消える。残す期間を過ぎた候補を人がタスクにできてしまう。
extension AutomationStoreTests {
  /// 既定の設定で出来事を残す期間。
  private static let eventRetention =
    TimeInterval(AutomationRetention.standard.eventDays) * AutomationDatabase.day

  /// 取得 f1（`f1` の出力の性質）・f2（今の集合）→ 判定 の自動化の定義。`judgeFrom` は判定の入力。
  private func gathering(
    judgeFrom inputs: [String] = ["f1", "f2"], f1: AutomationCoverage = .currentSet
  ) -> AutomationDefinition {
    let fetch = { (key: String, coverage: AutomationCoverage) in
      DesignSceneFixtures.commandNode(
        key, key, .scheduled(.every(1800)), script: key, coverage: coverage)
    }
    return AutomationDefinition(
      name: "集める", notify: nil,
      nodes: [
        fetch("f1", f1), fetch("f2", .currentSet),
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

  /// 取得（今の集合）→ 処理（出来事の流れ、入力の id を保って本文を書き換える）→ 判定 の自動化で、判定が処理の行 `a` から候補に
  /// した状態。自動化の ID を返す。
  private func passedOnByAProcess(_ store: AutomationStore) throws -> Int {
    var definition = Self.definition()
    definition.nodes[1].from = [AutomationDefinition.Input(nodeKey: "p")]
    definition.nodes.insert(
      DesignSceneFixtures.commandNode("p", "要約", .arrival, from: ["fetch"], script: "p"), at: 1)
    let id = try store.create(definition, now: Self.at).id
    try Self.fetch(store, id, [Self.item("a")])
    let input = try XCTUnwrap(
      store.read(store.nodeId(id, "p"), of: id, baseline: nil, now: Self.at)?.taken.first)
    let summary = AutomationNodeRow(
      id: input.id,
      text: #"{"id":"\#(input.id)","link":"\#(Self.link("a"))","body":"要約した本文"}"#, ref: nil,
      source: input.source)
    try store.record(
      id, nodeKey: "p", at: Self.at, outcome: DesignSceneFixtures.processed([summary], read: 1))
    try Self.judge(store, id, proposing: [Self.item("a")])
    return id
  }

  /// 処理が引き継いだ行の候補は、本文が処理の書いた本文で、出どころのノードは取得。取得がその項目を外すと下がり、取得の回に数える。
  func testAProposalOfARowAProcessPassedOnIsWithdrawnWhenTheFetchDropsItsItem() throws {
    let store = AutomationStore()
    let id = try passedOnByAProcess(store)

    let proposal = try XCTUnwrap(store.proposals.first)
    XCTAssertEqual(proposal.fields.body, "要約した本文")
    XCTAssertEqual(proposal.originNodeId, store.nodeId(id, "fetch"))

    try Self.fetch(store, id, [])
    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(store.automation(id)?.state(key: "fetch").runs.first?.run?.withdrawn, 1)
  }

  /// 判定が読んだ処理の出来事が残す期間を過ぎても、引き継ぎの元の取得の項目が今有効な間は残る（元の行の保存の規則に従う）。
  /// 取得がその項目を外すと下がり、取得の回に数える。
  func testAProposalOfAnEventFromACurrentSetItemOutlivesTheEventWhileTheItemStays() throws {
    let store = AutomationStore()
    let id = try passedOnByAProcess(store)
    let later = Self.at.addingTimeInterval(Self.eventRetention + 60)

    try Self.fetch(store, id, [Self.item("a")], at: later)
    XCTAssertEqual(store.proposals.map(\.state), [.open])

    try Self.fetch(store, id, [], at: later)
    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(store.automation(id)?.state(key: "fetch").runs.first?.run?.withdrawn, 1)
    XCTAssertEqual(try store.carried(id, "judge").withdrawn, 0)
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

  /// さばいた候補のリンクは、判定へ行が届く処理の今有効な項目にある間は覚え、処理がその行を書き換えて出し直しても判定の前で
  /// 捨てる（さばいた候補が戻らない）。
  func testAClosedProposalStaysClosedWhileAProcessStillHasItsRow() throws {
    let store = AutomationStore()
    var process = DesignSceneFixtures.commandNode(
      "p", "まとめ", .arrival, from: ["fetch"], script: "p", coverage: .currentSet)
    process.from = [AutomationDefinition.Input(nodeKey: "fetch", take: .all)]
    var definition = Self.definition()
    definition.nodes[1].from = [AutomationDefinition.Input(nodeKey: "p")]
    definition.nodes.insert(process, at: 1)
    let id = try store.create(definition, now: Self.at).id
    try Self.fetch(store, id, [Self.item("a")])
    func thread(_ body: String) -> AutomationNodeRow {
      AutomationNodeRow(
        id: "t1", text: #"{"id":"t1","link":"https://example.com/t1","body":"\#(body)"}"#,
        ref: nil, source: nil)
    }
    try store.record(
      id, nodeKey: "p", at: Self.at,
      outcome: DesignSceneFixtures.processed([thread("1 件")], read: 1))
    try Self.judge(
      store, id, proposing: [AutomationItem(id: "t1", link: Self.link("t1"), body: "", time: nil)])
    try store.dismiss(try XCTUnwrap(store.proposals.first).id, now: Self.at)

    try store.record(
      id, nodeKey: "p", at: Self.at.addingTimeInterval(60),
      outcome: DesignSceneFixtures.processed([thread("2 件")], read: 1))

    XCTAssertEqual(store.proposals.map(\.state), [.dismissed])
    XCTAssertEqual(store.automation(id)?.state(key: "judge").pending.count, 0)
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

  /// 元にした行がどれも出来事の候補は、判定が読んだ出来事が残す期間を過ぎると下げ、判定の持ち越しに数えて、判定の次の成功した
  /// 回の記録に載せる（読む前に期限で消えた出来事と同じく、受け手の次の回に）。取る行が 0 件の契機と失敗した回は持ち越しを保つ。
  func testAProposalOfAnEventIsWithdrawnWhenTheEventOutlivesItsRetention() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    let later = Self.at.addingTimeInterval(Self.eventRetention + 60)

    try Self.fetch(store, id, [Self.item("b")], at: later)
    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(try store.carried(id, "judge").withdrawn, 1)

    let judge = store.nodeId(id, "judge")
    var nothing = try XCTUnwrap(store.read(judge, of: id, baseline: nil, now: later))
    XCTAssertFalse(nothing.reach.isEmpty, "前提: 読む上限がある")
    nothing.taken = []
    try store.discard(nothing, of: judge, in: id, now: later)
    XCTAssertEqual(try store.carried(id, "judge").withdrawn, 1, "取る行が 0 件の契機")
    try store.record(id, nodeKey: "judge", at: later, outcome: DesignSceneFixtures.failed("boom"))
    XCTAssertEqual(try store.carried(id, "judge").withdrawn, 1, "失敗した回")

    try Self.judge(store, id, at: later)
    XCTAssertEqual(store.automation(id)?.state(key: "judge").runs.first?.run?.withdrawn, 1)
    XCTAssertEqual(try store.carried(id, "judge"), AutomationCarried())
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

  /// 判定が読んだ出来事が残す期間を過ぎても、判定の入力に同じリンクの残す期間の内の出来事があれば下げない——その時刻の判定の
  /// 確定でも（判定はその出来事を、既に候補があるとして捨てている）。その出来事も残す期間を過ぎると下げる。
  func testAnExpiredEventKeepsItsProposalWhileTheInputHasALaterEventWithItsLink() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    let again = Self.at.addingTimeInterval(20 * 86400)
    let followUp = AutomationItem(id: "a2", link: Self.link("a"), body: "a の続き", time: again)
    try Self.fetch(store, id, [followUp], at: again)
    try Self.judge(store, id, proposing: [followUp], at: again)
    XCTAssertEqual(store.proposals.map(\.state), [.open], "前提: 同じリンクの候補は 1 つ")

    try Self.judge(store, id, at: Self.at.addingTimeInterval(Self.eventRetention + 60))
    XCTAssertEqual(store.proposals.map(\.state), [.open])

    try Self.fetch(store, id, [], at: again.addingTimeInterval(Self.eventRetention + 60))
    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(try store.carried(id, "judge").withdrawn, 1)
  }

  /// 人がさばいた時刻に、判定が読んだ出来事が残す期間を過ぎていれば、候補はその時刻に下がり、タスクを足さず候補が無いと断る。
  func testAcceptingAProposalWhoseEventOutlivedItsRetentionAddsNoTask() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    let proposal = try XCTUnwrap(store.proposals.first)
    let tasks = TaskStore()
    let count = tasks.tasks.count

    XCTAssertThrowsError(
      try store.accept(
        proposal.id, into: tasks, workspace: nil,
        now: Self.at.addingTimeInterval(Self.eventRetention + 60))
    ) { XCTAssertEqual($0 as? AutomationError, .proposalNotFound(proposal.id)) }
    XCTAssertEqual(tasks.tasks.count, count)
    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(try store.carried(id, "judge").withdrawn, 1)
  }
}
