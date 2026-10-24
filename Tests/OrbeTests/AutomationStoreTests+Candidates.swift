import XCTest

@testable import Orbe

/// 候補の保ち方——出どころの性質ごとの下げ方と、判定の確定がその時点の候補に当て直されること。
///
/// 壊れると何が起きるか: 担当から外れた課題の候補が棚に残り続ける、または新着の DM の候補が次の取得で一斉に消える。同じリンクの
/// 候補が自動化ごとに二重に出る。人がタスクにした・捨てた候補を、判定が対応済みで上書きする。消した自動化の候補が、見えない
/// まま同じリンクを塞ぎ続ける。
extension AutomationStoreTests {
  private func proposals(_ store: AutomationStore) -> [String: AutomationProposal.State] {
    Dictionary(uniqueKeysWithValues: store.proposals.map { ($0.item.link, $0.state) })
  }

  /// 出どころの項目が今の集合から消えた（無効になった）候補は下げ、その取得の回に数える。戻ってきた項目はまた候補にできる。
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
    XCTAssertEqual(proposals(store), [a.link: .open])
  }

  /// 判定が読んだ後に出どころの項目が無効になったら、その案は確定で理由付きで捨て、判断待ちの候補に残さない。
  func testAProposalWhoseOriginWasInvalidatedMidRunIsDismissed() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .currentSet), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    let judge = store.part(id, "judge")
    let read = try XCTUnwrap(store.read(judge, of: id, baseline: nil, now: Self.at))
    try Self.fetch(store, id, [])

    try store.record(
      AutomationPassEnd(
        automationId: id, part: judge,
        defId: try XCTUnwrap(store.automation(id)?.graph.node(judge)).entity.defId,
        trigger: .arrival, startedAt: Self.at, endedAt: Self.at, read: read,
        outcome: DesignSceneFixtures.judged(
          [
            AutomationPartPass.Proposal(
              origin: try XCTUnwrap(read.taken.first?.origin), title: "対応: a", due: nil,
              workspace: nil, reason: nil)
          ], rows: 1)))

    XCTAssertEqual(proposals(store), [:])
    let run = store.automation(id)?.state(key: "judge").runs.first?.run
    guard case .judge(0, 0, let dismissed) = run?.result else { return XCTFail("判定の回が記録されない") }
    XCTAssertEqual(dismissed.map(\.why), [.originInvalidated])
  }

  /// 人がさばいて誰も持たなくなった候補はその場で忘れ、同じリンクの行を待つ別の判定の読めば取る行をすぐ数え直す。
  func testADecisionForgetsAnUnheldProposalAndRecountsTheOtherJudges() throws {
    let store = AutomationStore()
    let first = try store.create(Self.definition("一つ目", coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, first, [a])
    try Self.judge(store, first, proposing: [a])
    let second = try store.create(Self.definition("二つ目", coverage: .newArrivals), now: Self.at).id
    try Self.fetch(store, second, [a])
    XCTAssertEqual(
      store.automation(second)?.state(key: "judge").pending.count, 0, "前提: 候補のあるリンクの行は数えない")

    try store.dismiss(XCTUnwrap(store.proposals.first?.id), now: Self.at)

    XCTAssertEqual(proposals(store), [:])
    XCTAssertEqual(store.automation(second)?.state(key: "judge").pending.count, 1)
  }

  /// 出どころが出来事の候補は、取得から消えても判定が対応済みにするまで残り、対応済みになれば（誰も持たないので）忘れる。
  func testANewArrivalsProposalStaysUntilTheJudgeResolvesIt() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])

    try Self.fetch(store, id, [])
    XCTAssertEqual(proposals(store), [a.link: .open])

    try Self.judge(store, id, resolving: [a.link])
    XCTAssertEqual(proposals(store), [:])
  }

  /// 判定の確定はその時点の候補に当て直す: 別の自動化が先に候補にしたリンクの案は理由付きで捨て、人がさばいた候補を対応済みで
  /// 上書きしない。
  func testAJudgeCommitIsCheckedAgainstTheProposalsAtThatMoment() throws {
    let store = AutomationStore()
    let first = try store.create(Self.definition("一つ目"), now: Self.at).id
    let second = try store.create(Self.definition("二つ目"), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, first, [a])
    try Self.fetch(store, second, [a])
    let judge = store.part(second, "judge")
    let read = try XCTUnwrap(store.read(judge, of: second, baseline: nil, now: Self.at))
    try Self.judge(store, first, proposing: [a])

    try store.record(
      AutomationPassEnd(
        automationId: second, part: judge,
        defId: try XCTUnwrap(store.automation(second)?.graph.node(judge)).entity.defId,
        trigger: .arrival, startedAt: Self.at, endedAt: Self.at, read: read,
        outcome: DesignSceneFixtures.judged(
          [
            AutomationPartPass.Proposal(
              origin: try XCTUnwrap(read.taken.first?.origin), title: "対応: a", due: nil,
              workspace: nil, reason: nil)
          ], rows: 1)))
    XCTAssertEqual(
      store.proposals.map { store.issuer(of: $0)?.id }, [first], "リンクの候補は全自動化を通じて 1 つ")
    let run = store.automation(second)?.state(key: "judge").runs.first?.run
    guard case .judge(0, 0, let rejected) = run?.result else { return XCTFail("二つ目の判定の回が記録されない") }
    XCTAssertEqual(rejected.count, 1)

    try store.dismiss(XCTUnwrap(store.proposals.first?.id))
    try Self.judge(store, first, resolving: [a.link])
    XCTAssertEqual(proposals(store), [a.link: .dismissed])
  }

  /// 出どころが出来事で人がさばいた候補はその場で忘れ、後の取得の回の「下げた」には数えない。
  func testANewArrivalsProposalTheUserHandledIsForgottenAtOnceAndNotCountedAsWithdrawn() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    try store.dismiss(XCTUnwrap(store.proposals.first?.id))
    XCTAssertEqual(proposals(store), [:])

    try Self.fetch(store, id, [])

    XCTAssertEqual(store.automation(id)?.state(key: "fetch").runs.first?.run?.withdrawn, 0)
  }

  /// 出どころが出来事の判断待ちの候補は、取得の性質の書き換えでは下がらず、自動化を消して持ち主がいなくなると忘れる。
  func testRewritingKeepsEventProposalsButDeletingForgetsThem() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let (a, b) = (Self.item("a"), Self.item("b"))
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    try Self.fetch(store, id, [b])
    try Self.judge(store, id, proposing: [b])
    XCTAssertEqual(proposals(store), [a.link: .open, b.link: .open], "前提: 新着の流れは消えた a も持つ")

    try Self.rewrite(store, id, Self.definition(coverage: .currentSet))
    XCTAssertEqual(proposals(store), [a.link: .open, b.link: .open])

    try store.delete(id, now: Self.at)
    XCTAssertEqual(proposals(store), [:])
  }

  /// 判定に見せる判断待ちの候補は、その判定へ行が届く取得の今有効な項目にあるリンクのものと、その判定が出したもの。ほかの判定が
  /// 出し、どちらにも当たらない候補は見せない。
  func testAJudgeSeesProposalsOfItsFetchesLiveItemsAndItsOwn() throws {
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
      store.openProposals(of: id, judge: store.part(id, "judge")).map(\.item.link)
    }

    XCTAssertEqual(seen(first), [a.link])
    XCTAssertEqual(seen(second), [a.link, b.link], "取得の項目にあるリンクはほかの判定の候補も見せる")
    XCTAssertEqual(seen(stream), [c.link], "出来事は取得に無くても自分の候補を見せる")
  }
}
