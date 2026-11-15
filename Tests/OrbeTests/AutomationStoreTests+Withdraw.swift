import XCTest

@testable import Orbe

/// 判定ごとの候補の保ち方——処理を通った行の下げ方、出来事の残す期間での下げ方、毎回すべてを読む判定の覚え方。
///
/// 壊れると何が起きるか: 取得 → 処理 → 判定 の形で、取得が外した項目の候補が棚に残り続ける。処理がまとめた行の候補が、処理が
/// 外しても棚に残り続ける。処理がまとめた行を書き換えるたびに、さばいた候補が戻る。さばいた候補の項目が消えてまた現れても判定に
/// 届かない。直近の窓を毎回読む判定で、さばいた候補が次の回に戻る。取得（今の集合）→ 処理（出来事）→ 判定 で、取得にまだある
/// 課題の候補が出来事の残す期間で消える。同じリンクの出来事が続けて届く取得で、最初の出来事の残す期間で候補が消える。残す期間を
/// 過ぎた候補を人がタスクにできてしまう。出来事の残す日数を書いたノードの候補が、その日数でなく設定の日数で下がる・残る。
/// 取得 → 今の集合の処理 → 判定 で、取得が外した項目の候補が処理の次の回まで棚に残る。絞り込みの処理が外してまた出した項目が、
/// 人がさばいた後に判定に届かない。
extension AutomationStoreTests {
  /// 既定の設定で出来事を残す期間。
  static let eventRetention =
    TimeInterval(AutomationRetention.standard.eventDays) * AutomationDatabase.day

  /// 取得（今の集合）→ 処理（出来事の流れ、入力の id を保って本文を書き換える）→ 判定 の自動化で、判定が処理の行 `a` から候補に
  /// した状態。自動化の ID を返す。
  private func passedOnByAProcess(_ store: AutomationStore) throws -> Int {
    var definition = Self.definition()
    definition.nodes[1].from = [AutomationDefinition.Input(nodeKey: "p")]
    definition.nodes.insert(
      DesignSceneFixtures.commandNode("p", "要約", .arrival, from: ["fetch"], script: "p"), at: 1)
    let id = try store.create(definition, now: Self.at).id
    try Self.fetch(store, id, [Self.item("a")])
    try summarize(store, id)
    try Self.judge(store, id, proposing: [Self.item("a")])
    return id
  }

  /// `passedOnByAProcess` の処理 `p` の、取った行の id を保って本文を書き換えた行を出す回を確定する。
  private func summarize(_ store: AutomationStore, _ id: Int, at: Date = AutomationStoreTests.at)
    throws
  {
    let input = try XCTUnwrap(
      store.read(store.nodeId(id, "p"), of: id, baseline: nil, now: at)?.taken.first)
    let summary = AutomationNodeRow(
      id: input.id,
      text: #"{"id":"\#(input.id)","link":"\#(Self.link("a"))","body":"要約した本文"}"#, ref: nil,
      source: input.source)
    try store.record(
      id, nodeKey: "p", at: at, outcome: DesignSceneFixtures.processed([summary], read: 1))
  }

  /// 処理が引き継いだ行の候補を人が捨てた後、取得がその項目を外してまた出すと、処理が引き継いだ新しい出来事は判定に届き、候補に
  /// できる（元の項目が無効になった出来事は、さばいた候補を覚える支えにならない）。
  func testAHandledProposalOfAProcessedRowLetsTheItemThatCameBackReachTheJudge() throws {
    let store = AutomationStore()
    let id = try passedOnByAProcess(store)
    try store.dismiss(try XCTUnwrap(store.proposals.first).id, now: Self.at)
    let later = Self.at.addingTimeInterval(60)

    try Self.fetch(store, id, [], at: later)
    try Self.fetch(store, id, [Self.item("a")], at: later)
    try summarize(store, id, at: later)

    XCTAssertEqual(store.automation(id)?.state(key: "judge").pending.count, 1)
    try Self.judge(store, id, proposing: [Self.item("a")], at: later)
    XCTAssertEqual(store.proposals.map(\.state), [.open])
  }

  /// 取得（今の集合）→ 今の集合の処理 `p`（入力の id を保ち、`trigger` で動く）→ 判定 の自動化。自動化の ID を返す。
  private func keptByACurrentSetProcess(
    _ store: AutomationStore, _ trigger: AutomationNode.Trigger = .arrival
  ) throws -> Int {
    var process = DesignSceneFixtures.commandNode(
      "p", "絞り込み", trigger, script: "p", coverage: .currentSet)
    process.from = [AutomationDefinition.Input(nodeKey: "fetch", take: .all)]
    var definition = Self.definition()
    definition.nodes[1].from = [AutomationDefinition.Input(nodeKey: "p")]
    definition.nodes.insert(process, at: 1)
    return try store.create(definition, now: Self.at).id
  }

  /// `keptByACurrentSetProcess` の処理 `p` の回を確定する。`keeping` なら取った行をすべて id を保って出し、そうでなければ何も出さない。
  private func filter(
    _ store: AutomationStore, _ id: Int, keeping: Bool, at: Date = AutomationStoreTests.at
  ) throws {
    let taken = try XCTUnwrap(store.read(store.nodeId(id, "p"), of: id, baseline: nil, now: at))
      .taken
    let rows = taken.map {
      AutomationNodeRow(id: $0.id, text: $0.text, ref: nil, source: $0.source)
    }
    try store.record(
      id, nodeKey: "p", at: at,
      outcome: DesignSceneFixtures.processed(keeping ? rows : [], read: taken.count))
  }

  /// 取得 → 絞り込みの今の集合の処理 → 判定 で、人が捨てた候補は、処理がその項目を外すと忘れ、処理が同じ項目をまた出すと、その項目は
  /// 判定に届いて候補にできる（絞り込みを取得の条件に置いた形と同じ）。
  func testAHandledProposalIsForgottenWhenTheFilterDropsItsItem() throws {
    let store = AutomationStore()
    let id = try keptByACurrentSetProcess(store)
    try Self.fetch(store, id, [Self.item("a")])
    try filter(store, id, keeping: true)
    try Self.judge(store, id, proposing: [Self.item("a")])
    try store.dismiss(try XCTUnwrap(store.proposals.first).id, now: Self.at)

    try filter(store, id, keeping: false)
    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(
      store.automation(id)?.state(key: "p").runs.first?.run?.withdrawn, 0, "人がさばいた候補を忘れた分は数えない")
    try filter(store, id, keeping: true)

    XCTAssertEqual(store.automation(id)?.state(key: "judge").pending.count, 1)
    try Self.judge(store, id, proposing: [Self.item("a")])
    XCTAssertEqual(store.proposals.map(\.state), [.open])
  }

  /// 取得 → 予定で動く今の集合の処理（入力の id を保つ）→ 判定 で、処理の行の候補は、処理がまだ回っていなくても、取得が元の項目を外した
  /// 回の確定で下がり、取得のその回に数える。
  func testAProposalOfARowACurrentSetProcessKeptIsWithdrawnWhenTheFetchDropsItsItem() throws {
    let store = AutomationStore()
    let id = try keptByACurrentSetProcess(store, .scheduled(.every(1800)))
    try Self.fetch(store, id, [Self.item("a")])
    try filter(store, id, keeping: true)
    try Self.judge(store, id, proposing: [Self.item("a")])

    try Self.fetch(store, id, [])

    XCTAssertEqual(store.proposals, [])
    XCTAssertEqual(store.automation(id)?.state(key: "fetch").runs.first?.run?.withdrawn, 1)
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

  /// 出来事を毎回すべて読む判定が対応済みにした候補は、読んだ出来事が残す期間を過ぎるまで覚え（窓を外れても）、そのリンクに
  /// 新しい変化が無い間は、その出来事を判定の前で捨てる。
  func testAJudgeReadingAWindowEveryRunRemembersAResolvedProposalUntilItsEventExpires() throws {
    let store = AutomationStore()
    var definition = Self.definition(coverage: .newArrivals)
    definition.nodes[1].from = [
      AutomationDefinition.Input(nodeKey: "fetch", take: .all, maxAgeHours: 24)
    ]
    let id = try store.create(definition, now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    try Self.judge(store, id, resolving: [Self.link("a")])

    XCTAssertEqual(store.proposals.map(\.state), [.resolved])
    let judge = store.nodeId(id, "judge")
    let read = try XCTUnwrap(store.read(judge, of: id, baseline: nil, now: Self.at))
    XCTAssertEqual(read.taken, [])
    XCTAssertEqual(store.automation(id)?.state(key: "judge").pending.count, 0)

    try Self.fetch(store, id, [], at: Self.at.addingTimeInterval(25 * 3600))
    XCTAssertEqual(store.proposals.map(\.state), [.resolved], "窓を外れても、出来事が残す期間の内は覚える")
    try Self.fetch(store, id, [], at: Self.at.addingTimeInterval(Self.eventRetention + 60))
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
    try store.endEmptyTrigger(nothing, of: judge, in: id, now: later)
    XCTAssertEqual(try store.carried(id, "judge").withdrawn, 1, "取る行が 0 件の契機")
    try store.record(id, nodeKey: "judge", at: later, outcome: DesignSceneFixtures.failed("boom"))
    XCTAssertEqual(try store.carried(id, "judge").withdrawn, 1, "失敗した回")

    try Self.judge(store, id, at: later)
    XCTAssertEqual(store.automation(id)?.state(key: "judge").runs.first?.run?.withdrawn, 1)
    XCTAssertEqual(try store.carried(id, "judge"), AutomationCarried())
  }

  /// 判定が読んだ出来事の残す期間は、出したノードの出来事の残す日数で、書かなければ設定の日数——ノードの日数を過ぎた候補は
  /// 設定の日数の内でも下がり、日数を書かないノードの候補は設定の日数まで残る。
  func testAProposalOfAnEventIsWithdrawnByTheDaysOfTheNodeThatWroteIt() throws {
    let store = AutomationStore(
      opening: AutomationPersistence.open(retention: {
        AutomationRetention(runCount: 20, runDays: 7, eventDays: 20)
      }))
    var short = Self.definition("10 日", coverage: .newArrivals)
    short.nodes[0].retentionDays = 10
    let shortId = try store.create(short, now: Self.at).id
    let plainId = try store.create(Self.definition("設定", coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    for id in [shortId, plainId] {
      try Self.fetch(store, id, [a])
      try Self.judge(store, id, proposing: [a])
    }
    func states(_ id: Int) -> [AutomationProposal.State] {
      store.proposals.filter { $0.judge == store.nodeId(id, "judge") }.map(\.state)
    }

    try Self.fetch(store, shortId, [], at: Self.at.addingTimeInterval(11 * AutomationDatabase.day))
    XCTAssertEqual(states(shortId), [])
    XCTAssertEqual(try store.carried(shortId, "judge").withdrawn, 1)
    XCTAssertEqual(states(plainId), [.open], "設定の 20 日の内")

    try Self.fetch(store, plainId, [], at: Self.at.addingTimeInterval(21 * AutomationDatabase.day))
    XCTAssertEqual(states(plainId), [])
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
