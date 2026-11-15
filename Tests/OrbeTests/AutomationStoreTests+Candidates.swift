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

  /// ほかの自動化の候補は、同じリンクの行を判定が読むのを妨げない（人がさばいた候補でも）。
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

    XCTAssertEqual(proposals(store), [Self.link("a"): .dismissed])
    XCTAssertEqual(store.automation(second)?.state(key: "judge").pending.count, 1)
  }

  /// 元にした行が出来事の候補は、取得から消えても判定が対応済みにするまで残り、対応済みになっても、下げる条件を満たすまで（読んだ
  /// 出来事が残す期間の内は）覚える。判断待ちの候補のリンクの新しい行は判定へ渡る（判定が対応済みにする手がかり）。
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
    XCTAssertEqual(proposals(store), [Self.link("a"): .resolved])
  }

  /// `coverage` の取得を `take` で読む判定が、項目 `a` を候補にして対応済みにした状態。自動化の ID を返す。
  private func resolvedA(
    _ store: AutomationStore, _ coverage: AutomationCoverage, take: AutomationTake
  ) throws -> Int {
    var definition = Self.definition(coverage: coverage)
    definition.nodes[1].from = [AutomationDefinition.Input(nodeKey: "fetch", take: take)]
    let id = try store.create(definition, now: Self.at).id
    try Self.fetch(store, id, [Self.item("a")])
    try Self.judge(store, id, proposing: [Self.item("a")])
    try Self.judge(store, id, resolving: [Self.link("a")])
    XCTAssertEqual(proposals(store), [Self.link("a"): .resolved], "前提")
    return id
  }

  /// 判定が時刻 `at` に読めば取る行のリンク。
  private func taken(_ store: AutomationStore, _ id: Int, at: Date = AutomationStoreTests.at) throws
    -> [String]
  {
    try XCTUnwrap(store.read(store.nodeId(id, "judge"), of: id, baseline: nil, now: at))
      .taken.compactMap(\.link)
  }

  /// 出来事を毎回すべて読む判定が対応済みにした候補について、そのリンクの行は、同じリンクの行が後から届いた回だけ、前に読んだ行も
  /// 含めてすべて判定に渡る。判定が案にしなければ対応済みの候補は残り、次の回からはまた渡らない。
  func testAResolvedLinkReachesAJudgeReadingEveryRunOnlyOnceItHasANewRow() throws {
    let store = AutomationStore()
    let id = try resolvedA(store, .newArrivals, take: .all)
    XCTAssertEqual(try taken(store, id), [], "新しい行が無ければ渡らない")

    try Self.fetch(
      store, id, [AutomationItem(id: "a2", link: Self.link("a"), body: "再依頼", time: Self.at)])

    XCTAssertEqual(try taken(store, id), [Self.link("a"), Self.link("a")])
    try Self.judge(store, id)
    XCTAssertEqual(proposals(store), [Self.link("a"): .resolved])
    XCTAssertEqual(try taken(store, id), [])
  }

  /// 判定が対応済みの候補について、そのリンクの行を案にすると、対応済みの候補は新しい判断待ちの候補に置き換わる。判定のその回の記録は、その
  /// 案を候補にした数（`proposed`）に数え、理由付きで捨てた案（`dismissed`）には載せない。
  func testProposingAResolvedLinkAgainReplacesTheResolvedProposal() throws {
    let store = AutomationStore()
    let id = try resolvedA(store, .newArrivals, take: .new)
    let resolved = try XCTUnwrap(store.proposals.first).id
    let again = AutomationItem(id: "a2", link: Self.link("a"), body: "再依頼", time: Self.at)
    try Self.fetch(store, id, [again])

    try Self.judge(store, id, proposing: [again])

    XCTAssertEqual(proposals(store), [Self.link("a"): .open])
    XCTAssertNotEqual(store.proposals.first?.id, resolved)
    XCTAssertEqual(
      store.automation(id)?.state(key: "judge").runs.first?.run?.result,
      .judge(proposed: 1, resolved: 0, dismissed: []))
  }

  /// 今の集合を毎回すべて読む判定には、対応済みの候補の項目の中身が変わると、その項目の行が渡る。
  func testAResolvedItemReachesAJudgeReadingEveryRunWhenItsBodyChanges() throws {
    let store = AutomationStore()
    let id = try resolvedA(store, .currentSet, take: .all)
    XCTAssertEqual(try taken(store, id), [], "前提: 変化が無ければ渡らない")

    let later = Self.at.addingTimeInterval(60)
    try Self.fetch(
      store, id, [AutomationItem(id: "a", link: Self.link("a"), body: "差し戻し", time: Self.at)],
      at: later)

    XCTAssertEqual(try taken(store, id, at: later), [Self.link("a")])
  }

  /// 今の集合の新しい項目だけを読む判定には、対応済みの候補の項目が有効なまま、同じリンクの別の項目が届くと、その別の項目が渡る。
  func testAResolvedLinkReachesAJudgeReadingNewItemsWhenAnotherItemOfItArrives() throws {
    let store = AutomationStore()
    let id = try resolvedA(store, .currentSet, take: .new)

    try Self.fetch(
      store, id,
      [Self.item("a"), AutomationItem(id: "a2", link: Self.link("a"), body: "別の項目", time: Self.at)])

    XCTAssertEqual(store.automation(id)?.state(key: "judge").pending.count, 1)
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
  /// したリンクの案は理由付きで捨て、人がさばいた候補を対応済みで上書きせず、対応済みに数えずに理由付きで捨てる。
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
    let resolving = store.automation(first)?.state(key: "judge").runs.first?.run
    guard case .judge(0, 0, let unresolved) = resolving?.result else {
      return XCTFail("一つ目の判定の対応済みにする回が記録されない")
    }
    XCTAssertEqual(unresolved.map(\.why), [.noOpenProposal])
  }

  /// 元にした行が出来事で人がさばいた候補は、そのリンクの出来事が上流に残る間は覚え、同じリンクの新しい出来事を判定の前で捨てて
  /// 判定の回の `closed` に数える（取得の回の「下げた」には数えない）。
  func testANewArrivalsProposalTheUserHandledKeepsLaterRowsOfItsLinkFromTheJudge() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    try store.dismiss(XCTUnwrap(store.proposals.first?.id), now: Self.at)
    let reply = AutomationItem(id: "a2", link: Self.link("a"), body: "a への返信", time: Self.at)

    try Self.fetch(store, id, [reply, Self.item("b")])

    XCTAssertEqual(store.automation(id)?.state(key: "fetch").runs.first?.run?.withdrawn, 0)
    XCTAssertEqual(store.automation(id)?.state(key: "judge").pending.count, 1, "b だけが判定に届く")
    try Self.judge(store, id)
    XCTAssertEqual(
      store.automation(id)?.state(key: "judge").runs.first?.run?.dropped.counts, [.closed: 1])
    XCTAssertEqual(proposals(store), [Self.link("a"): .dismissed])
  }

  /// 人がさばいた候補のリンクの出来事がどれも残す期間を過ぎた後に同じリンクの出来事が届けば、その間にほかの変異が無くても判定に
  /// 届き、候補にできる。
  func testARowOfAHandledLinkReachesTheJudgeOnceEveryEventOfTheLinkExpired() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(coverage: .newArrivals), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    try store.accept(
      XCTUnwrap(store.proposals.first?.id), into: TaskStore(), workspace: nil, now: Self.at)
    let later = Self.at.addingTimeInterval(Self.eventRetention + 60)
    let reply = AutomationItem(id: "a2", link: Self.link("a"), body: "a への返信", time: later)

    try Self.fetch(store, id, [reply], at: later)

    XCTAssertEqual(store.automation(id)?.state(key: "judge").pending.count, 1)
    try Self.judge(store, id, proposing: [reply], at: later)
    XCTAssertEqual(proposals(store), [Self.link("a"): .open])
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
