import XCTest

@testable import Orbe

/// 候補の保ち方——取得の性質ごとの下げ方と、判定の確定がその時点の候補に当て直されること。
///
/// 壊れると何が起きるか: 担当から外れた課題の候補が棚に残り続ける、または新着の DM の候補が次の取得で一斉に消える。同じリンクの
/// 候補が自動化ごとに二重に出る。人がタスクにした・捨てた候補を、判定が対応済みで上書きする。
extension AutomationStoreTests {
  private func proposals(_ store: AutomationStore) -> [String: AutomationProposal.State] {
    Dictionary(uniqueKeysWithValues: store.proposals.map { ($0.item.link, $0.state) })
  }

  /// 今の集合の取得から消えたリンクの候補は下げ、その取得の回に数える。戻ってきたリンクはまた候補にできる。
  func testACurrentSetProposalIsWithdrawnWhenItsLinkLeavesAndCanBeProposedAgain() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .currentSet), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])

    try Self.fetch(store, id, [])
    XCTAssertEqual(proposals(store), [:])
    XCTAssertEqual(store.automation(id)?.state("fetch").runs.first?.withdrawn, 1)

    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    XCTAssertEqual(proposals(store), [a.link: .open])
  }

  /// 新着の流れの候補は、取得から消えても判定が対応済みにするまで残り、対応済みになれば忘れる。
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
    try Self.judge(store, first, proposing: [a])

    try Self.judge(store, second, proposing: [a])
    XCTAssertEqual(store.proposals.map(\.automationId), [first], "リンクの候補は全自動化を通じて 1 つ")
    let run = store.automation(second)?.state("judge").runs.first
    guard case .judge(0, 0, let rejected) = run?.result else { return XCTFail("二つ目の判定の回が記録されない") }
    XCTAssertEqual(rejected.count, 1)

    try store.dismiss(XCTUnwrap(store.proposals.first?.id))
    try Self.judge(store, first, resolving: [a.link])
    XCTAssertEqual(proposals(store), [a.link: .dismissed])
  }

  /// 新着の流れで人がさばいた候補は、取得から消えたら忘れ、その取得の回の「下げた」には数えない。
  func testANewArrivalsProposalTheUserHandledIsForgottenOnceItsLinkLeaves() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    try store.dismiss(XCTUnwrap(store.proposals.first?.id))

    try Self.fetch(store, id, [])

    XCTAssertEqual(proposals(store), [:])
    XCTAssertEqual(store.automation(id)?.state("fetch").runs.first?.withdrawn, 0)
  }

  /// 持ち主がいなくなる書き換え・削除でも候補を忘れる: 新着の流れを今の集合に書き換えると取得に無いリンクの候補を忘れ、自動化を
  /// 消すとその自動化だけが持っていた候補を忘れる。
  func testRewritingOrDeletingForgetsProposalsNoLongerHeld() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let (a, b) = (Self.item("a"), Self.item("b"))
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    try Self.fetch(store, id, [b])
    try Self.judge(store, id, proposing: [b])
    XCTAssertEqual(proposals(store), [a.link: .open, b.link: .open], "前提: 新着の流れは消えた a も持つ")

    _ = try store.replace(id, with: Self.definition(coverage: .currentSet), now: Self.at)
    XCTAssertEqual(proposals(store), [b.link: .open])

    try store.delete(id)
    XCTAssertEqual(proposals(store), [:])
  }

  /// 判定に見せる判断待ちの候補は、その判定へ行が届く取得の前回の出力にあるリンクのものと、その判定が出した新着の流れのもの。
  /// ほかの判定が出し、どちらにも当たらない候補は見せない。
  func testAJudgeSeesProposalsOfItsFetchesOutputAndItsOwnNewArrivals() throws {
    let store = AutomationStore()
    let set = try store.create(Self.definition("今の集合", coverage: .currentSet), now: Self.at).id
    let stream = try store.create(Self.definition("新着", coverage: .newArrivals), now: Self.at).id
    let (a, b) = (Self.item("a"), Self.item("b"))
    try Self.fetch(store, set, [a])
    try Self.judge(store, set, proposing: [a])
    try Self.fetch(store, stream, [a, b])
    try Self.judge(store, stream, proposing: [b])
    try Self.fetch(store, stream, [])
    func seen(_ id: Int) -> [String] {
      store.openProposals(of: id, judge: "judge").map(\.item.link)
    }

    XCTAssertEqual(seen(set), [a.link])
    XCTAssertEqual(seen(stream), [b.link], "取得から消えても自分の新着の流れは見せる")
    try Self.fetch(store, stream, [a])
    XCTAssertEqual(Set(seen(stream)), [a.link, b.link], "取得の出力にあるリンクはほかの判定の候補も見せる")
  }
}
