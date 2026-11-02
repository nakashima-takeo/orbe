import XCTest

@testable import Orbe

/// 候補の保ち方——元にした行の性質ごとの下げ方と、判定の確定がその時点のその判定の候補に当て直されること。
///
/// 壊れると何が起きるか: 担当から外れた課題の候補が棚に残り続ける、または新着の DM の候補が次の取得で一斉に消える。同じ判定の
/// 候補が同じリンクで二重に出る。ほかの自動化が先に候補にしたリンクを、別の自動化の判定が見落とす。人がタスクにした・捨てた
/// 候補を、判定が対応済みで上書きする。消した自動化の候補が、見えないまま残り続ける。
extension AutomationStoreTests {
  private func proposals(_ store: AutomationStore) -> [String: AutomationProposal.State] {
    Dictionary(uniqueKeysWithValues: store.proposals.map { ($0.link, $0.state) })
  }

  /// 元にした項目が今の集合から消えた（無効になった）候補は下げ、その取得の回に数える。戻ってきた項目はまた候補にできる。
  func testACurrentSetProposalIsWithdrawnWhenItsLinkLeavesAndCanBeProposedAgain() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .currentSet), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])

    try Self.fetch(store, id, [])
    XCTAssertEqual(proposals(store), [:])
    XCTAssertEqual(store.automation(id)?.state(key: "fetch").runs.first?.run?.withdrawn, 1)

    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    XCTAssertEqual(proposals(store), [Self.link("a"): .open])
  }

  /// 判定が読んだ後に元にした項目が無効になったら、その案は確定で理由付きで捨て、判断待ちの候補に残さない。
  func testAProposalWhoseRowStoppedBeingCurrentMidRunIsDismissed() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .currentSet), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    let judge = store.nodeId(id, "judge")
    let read = try XCTUnwrap(store.read(judge, of: id, baseline: nil, now: Self.at))
    try Self.fetch(store, id, [])

    try store.record(
      AutomationPassEnd(
        automationId: id, nodeId: judge,
        defId: try XCTUnwrap(store.automation(id)?.graph.node(judge)).entity.defId,
        trigger: .arrival, startedAt: Self.at, endedAt: Self.at, read: read,
        outcome: DesignSceneFixtures.judged(
          [try XCTUnwrap(read.taken.first?.proposal("対応: a"))], rows: 1)))

    XCTAssertEqual(proposals(store), [:])
    let run = store.automation(id)?.state(key: "judge").runs.first?.run
    guard case .judge(0, 0, let dismissed) = run?.result else { return XCTFail("判定の回が記録されない") }
    XCTAssertEqual(dismissed.map(\.why), [.noLongerCurrent])
  }

  /// ほかの自動化の候補は、同じリンクの行を判定が読むのを妨げない。人がさばいて覚えなくなった候補はその場で忘れる。
  func testAnotherAutomationsProposalDoesNotKeepAJudgeFromTheSameLink() throws {
    let store = AutomationStore()
    let first = try store.create(Self.definition("一つ目", coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, first, [a])
    try Self.judge(store, first, proposing: [a])
    let second = try store.create(Self.definition("二つ目", coverage: .newArrivals), now: Self.at).id
    try Self.fetch(store, second, [a])
    XCTAssertEqual(store.automation(second)?.state(key: "judge").pending.count, 1)

    try store.dismiss(XCTUnwrap(store.proposals.first?.id), now: Self.at)

    XCTAssertEqual(proposals(store), [:])
    XCTAssertEqual(store.automation(second)?.state(key: "judge").pending.count, 1)
  }

  /// 元にした行が出来事の候補は、取得から消えても判定が対応済みにするまで残り、対応済みになれば（リンクの行がまた届きえないので）
  /// 忘れる。判断待ちの候補のリンクの新しい行は判定へ渡る（判定が対応済みにする手がかり）。
  func testANewArrivalsProposalStaysUntilTheJudgeResolvesIt() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])

    try Self.fetch(store, id, [])
    XCTAssertEqual(proposals(store), [Self.link("a"): .open])

    let merged = AutomationItem(id: "a-merged", link: Self.link("a"), body: "マージされた", time: Self.at)
    try Self.fetch(store, id, [merged])
    XCTAssertEqual(store.automation(id)?.state(key: "judge").pending.count, 1)

    try Self.judge(store, id, resolving: [Self.link("a")])
    XCTAssertEqual(proposals(store), [:])
  }

  /// 同じリンクの行は判定へすべて届き、1 回でそのうち 2 つを案にしても候補は 1 つで、残りは理由付きで捨てる。
  func testOneRunProposingTwoRowsOfTheSameLinkMakesOneProposal() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(), now: Self.at).id
    let again = AutomationItem(id: "a2", link: Self.link("a"), body: "a の続き", time: Self.at)
    try Self.fetch(store, id, [Self.item("a"), again])
    let judge = store.nodeId(id, "judge")
    let read = try XCTUnwrap(store.read(judge, of: id, baseline: nil, now: Self.at))
    XCTAssertEqual(read.taken.count, 2, "前提: 同じリンクの行を絞らない")

    try store.record(
      AutomationPassEnd(
        automationId: id, nodeId: judge,
        defId: try XCTUnwrap(store.automation(id)?.graph.node(judge)).entity.defId,
        trigger: .arrival, startedAt: Self.at, endedAt: Self.at, read: read,
        outcome: DesignSceneFixtures.judged(
          read.taken.compactMap { $0.proposal("対応: \($0.id)") }, rows: 2)))

    XCTAssertEqual(store.proposals.map(\.link), [Self.link("a")])
    let run = store.automation(id)?.state(key: "judge").runs.first?.run
    guard case .judge(1, 0, let dismissed) = run?.result else { return XCTFail("判定の回が記録されない") }
    XCTAssertEqual(dismissed.map(\.why), [.alreadyProposed])
  }

  /// 判定の確定はその時点のその判定の候補に当て直す: 別の自動化が先に候補にしたリンクの案も候補になり、同じ判定が既に候補に
  /// したリンクの案は理由付きで捨て、人がさばいた候補を対応済みで上書きしない。
  func testAJudgeCommitIsCheckedAgainstItsOwnProposalsAtThatMoment() throws {
    let store = AutomationStore()
    let first = try store.create(Self.definition("一つ目"), now: Self.at).id
    let second = try store.create(Self.definition("二つ目"), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, first, [a])
    try Self.fetch(store, second, [a])
    let judge = store.nodeId(second, "judge")
    let read = try XCTUnwrap(store.read(judge, of: second, baseline: nil, now: Self.at))
    try Self.judge(store, first, proposing: [a])
    let end = AutomationPassEnd(
      automationId: second, nodeId: judge,
      defId: try XCTUnwrap(store.automation(second)?.graph.node(judge)).entity.defId,
      trigger: .arrival, startedAt: Self.at, endedAt: Self.at, read: read,
      outcome: DesignSceneFixtures.judged(
        [try XCTUnwrap(read.taken.first?.proposal("対応: a"))], rows: 1))

    try store.record(end)
    XCTAssertEqual(store.proposals.map { store.issuer(of: $0)?.id }, [first, second])
    try store.record(end)
    XCTAssertEqual(store.proposals.count, 2)
    let run = store.automation(second)?.state(key: "judge").runs.first?.run
    guard case .judge(0, 0, let rejected) = run?.result else { return XCTFail("二つ目の判定の回が記録されない") }
    XCTAssertEqual(rejected.map(\.why), [.alreadyProposed])

    try store.dismiss(XCTUnwrap(store.proposals.first?.id), now: Self.at)
    try Self.judge(store, first, resolving: [Self.link("a")])
    XCTAssertEqual(store.proposals.map(\.state), [.dismissed, .open])
  }

  /// 元にした行が出来事で人がさばいた候補はその場で忘れ、後の取得の回の「下げた」には数えない。
  func testANewArrivalsProposalTheUserHandledIsForgottenAtOnceAndNotCountedAsWithdrawn() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    try store.dismiss(XCTUnwrap(store.proposals.first?.id), now: Self.at)
    XCTAssertEqual(proposals(store), [:])

    try Self.fetch(store, id, [])

    XCTAssertEqual(store.automation(id)?.state(key: "fetch").runs.first?.run?.withdrawn, 0)
  }

  /// 元にした行が出来事の判断待ちの候補は、取得の性質の書き換えでは下がらず、自動化を消すと忘れる。
  func testRewritingKeepsEventProposalsButDeletingForgetsThem() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let (a, b) = (Self.item("a"), Self.item("b"))
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    try Self.fetch(store, id, [b])
    try Self.judge(store, id, proposing: [b])
    XCTAssertEqual(
      proposals(store), [Self.link("a"): .open, Self.link("b"): .open], "前提: 新着の流れは消えた a も持つ")

    try Self.rewrite(store, id, Self.definition(coverage: .currentSet))
    XCTAssertEqual(proposals(store), [Self.link("a"): .open, Self.link("b"): .open])

    try store.delete(id, now: Self.at)
    XCTAssertEqual(proposals(store), [:])
  }

  /// 判定に見せる判断待ちの候補は、その判定が出したものだけ。同じリンクでもほかの判定の候補は見せない。
  func testAJudgeSeesOnlyItsOwnProposals() throws {
    let store = AutomationStore()
    let first = try store.create(Self.definition("一つ目"), now: Self.at).id
    let second = try store.create(Self.definition("二つ目"), now: Self.at).id
    let stream = try store.create(Self.definition("新着", coverage: .newArrivals), now: Self.at).id
    let (a, b, c) = (Self.item("a"), Self.item("b"), Self.item("c"))
    try Self.fetch(store, first, [a])
    try Self.judge(store, first, proposing: [a])
    try Self.fetch(store, second, [a, b])
    try Self.judge(store, second, proposing: [b])
    try Self.fetch(store, stream, [c])
    try Self.judge(store, stream, proposing: [c])
    try Self.fetch(store, stream, [])
    func seen(_ id: Int) -> [String] {
      store.openProposals(of: store.nodeId(id, "judge")).map(\.link)
    }

    XCTAssertEqual(seen(first), [Self.link("a")])
    XCTAssertEqual(seen(second), [Self.link("b")], "取得の項目にあるリンクでも、ほかの判定の候補は見せない")
    XCTAssertEqual(seen(stream), [Self.link("c")], "出来事は取得に無くても自分の候補を見せる")
  }
}
