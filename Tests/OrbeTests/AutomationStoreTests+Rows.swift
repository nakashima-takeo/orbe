import XCTest

@testable import Orbe

/// 出す側がデータを持ち、受け取る側が取り方を持つ——今の集合（項目と版）と出来事の流れ（出来事）の持ち方、受け手ごとの読んだ
/// 位置と取り方（新しいものだけ・毎回すべて・古さの上限）、読む前に期限で消えた数、出来事の見分け、性質の書き換え。
///
/// 壊れると何が起きるか: 後から足した受け手に今の集合が届かない、または出来事の流れの過去が全部流れ込む。同じ項目が中身の
/// 変化で二重に届き、副作用が二重に走る。消えてまた現れた項目が届かない。期限で消えた出来事を黙って取りこぼす。同じ id の
/// 出来事が毎回届く、または日報のように id の違う出来事が届かない。失敗した回の行が二度と届かない。毎回すべてを取る受け手の
/// 捨てた数が回ごとに膨らむ。取得の余分な欄が下流で落ちる。
extension AutomationStoreTests {
  private static let day: TimeInterval = 86400

  /// 取得 `gh`（`coverage`）→ 副作用のコマンドの受け手 `a`。
  private func define(
    _ store: AutomationStore, coverage: AutomationCoverage,
    receivers: [AutomationDefinition.Node]? = nil
  ) throws -> Int {
    try store.create(
      AutomationDefinition(
        name: "受け手", notify: nil,
        parts: [
          DesignSceneFixtures.commandPart(
            "gh", "取る", .scheduled(.every(1800)), script: "gh", coverage: coverage)
        ] + (receivers ?? [receiver("a")])), now: Self.at
    ).id
  }

  private func receiver(
    _ key: String, from input: AutomationDefinition.Input = .init(part: "gh")
  ) -> AutomationDefinition.Node {
    var part = DesignSceneFixtures.commandPart(
      key, key, .arrival, from: [input.part], script: key, deliver: .sideEffect)
    part.from = [input]
    return part
  }

  private func fetch(_ store: AutomationStore, _ id: Int, _ ids: [String], at: Date) throws {
    try store.record(
      id, part: "gh", at: at, outcome: DesignSceneFixtures.fetched(ids.map(item(at))))
  }

  private func item(_ at: Date) -> (String) -> AutomationItem {
    { AutomationItem(id: $0, link: "https://example.com/\($0)", body: "\($0) の本文", time: at) }
  }

  /// 処理の部品 `copy` の、取った行をすべて引き継いで出す回を確定する。
  private func copyAll(_ store: AutomationStore, _ id: Int, at: Date) throws {
    let part = store.part(id, "copy")
    let read = try XCTUnwrap(store.read(part, of: id, baseline: nil, now: at))
    try store.record(
      AutomationPassEnd(
        automationId: id, part: part,
        defId: try XCTUnwrap(store.automation(id)?.graph.node(part)).entity.defId,
        trigger: .arrival, startedAt: at, endedAt: at, read: read,
        outcome: DesignSceneFixtures.processed(
          read.taken.map {
            AutomationNodeRow(id: $0.id, text: $0.text, origin: $0.origin, source: $0.source)
          }, read: read.taken.count)))
  }

  /// 受け手の回（読める行をすべて取る）。取った行の書かれた id（下流へ渡す id の接頭を外したもの）を返す。
  @discardableResult private func take(
    _ store: AutomationStore, _ id: Int, _ key: String, at: Date, failing: Bool = false
  ) throws -> [String] {
    let part = store.part(id, key)
    let read = try XCTUnwrap(store.read(part, of: id, baseline: nil, now: at))
    try store.record(
      AutomationPassEnd(
        automationId: id, part: part,
        defId: try XCTUnwrap(store.automation(id)?.graph.node(part)).entity.defId,
        trigger: .arrival, startedAt: at, endedAt: at, read: read,
        outcome: failing
          ? DesignSceneFixtures.failed("boom") : DesignSceneFixtures.sideEffected(read.taken.count))
    )
    return read.taken.map { String($0.id.split(separator: ":", maxSplits: 1).last ?? "") }
  }

  private func lastRun(_ store: AutomationStore, _ id: Int, _ key: String) -> AutomationNodeRun? {
    store.automation(id)?.state(key: key).runs.first?.run
  }

  // MARK: - 後から足した受け手

  /// 今の集合の取得の受け手を後から足すと、足した受け手には今の全件が、前からの受け手には新しい項目だけが届き、その次からは
  /// どちらにも新しい項目だけが届く。
  func testAReceiverAddedLaterGetsTheWholeCurrentSetOnce() throws {
    let store = AutomationStore()
    let id = try define(store, coverage: .currentSet)
    try fetch(store, id, ["x", "y"], at: Self.at)
    try take(store, id, "a", at: Self.at)
    var definition = try XCTUnwrap(store.automation(id)?.definition)
    definition.parts.append(receiver("b"))
    _ = try store.replace(id, version: 1, with: definition, now: Self.at)

    let t1 = Self.at.addingTimeInterval(1800)
    try fetch(store, id, ["x", "y", "z"], at: t1)
    XCTAssertEqual(try take(store, id, "a", at: t1), ["z"])
    XCTAssertEqual(try take(store, id, "b", at: t1), ["x", "y", "z"])

    let t2 = t1.addingTimeInterval(1800)
    try fetch(store, id, ["x", "y", "z", "w"], at: t2)
    XCTAssertEqual(try take(store, id, "a", at: t2), ["w"])
    XCTAssertEqual(try take(store, id, "b", at: t2), ["w"])
  }

  /// 出来事の流れの取得の受け手を後から足すと、足した後に作られた出来事だけが届く。
  func testAReceiverAddedLaterToEventsGetsOnlyLaterEvents() throws {
    let store = AutomationStore()
    let id = try define(store, coverage: .newArrivals)
    try fetch(store, id, ["x"], at: Self.at)
    var definition = try XCTUnwrap(store.automation(id)?.definition)
    definition.parts.append(receiver("b"))
    _ = try store.replace(id, version: 1, with: definition, now: Self.at)

    let t1 = Self.at.addingTimeInterval(1800)
    try fetch(store, id, ["x", "y"], at: t1)

    XCTAssertEqual(try take(store, id, "a", at: t1), ["x", "y"])
    XCTAssertEqual(try take(store, id, "b", at: t1), ["y"])
  }

  // MARK: - 取り方

  /// 毎回すべてを取る受け手には、回ごとに今の集合の全件が届く。同じ上流の新しいものだけの受け手には新しい項目だけ。出来事の流れ
  /// なら、毎回すべては古さの上限の内の出来事の窓になり、前に読んだ行が窓の外へ出ても捨てた数に数え直さない。
  func testTakingAllReadsTheWholeSetOrTheWindowEveryTime() throws {
    let store = AutomationStore()
    let set = try define(
      store, coverage: .currentSet,
      receivers: [receiver("a"), receiver("all", from: .init(part: "gh", take: .all))])
    let events = try define(
      store, coverage: .newArrivals,
      receivers: [receiver("window", from: .init(part: "gh", take: .all, maxAgeHours: 24))])
    try fetch(store, set, ["x"], at: Self.at)
    try fetch(store, events, ["old"], at: Self.at)
    try take(store, set, "a", at: Self.at)
    try take(store, set, "all", at: Self.at)
    try take(store, events, "window", at: Self.at)

    let t1 = Self.at.addingTimeInterval(Self.day + 3600)
    try fetch(store, set, ["x", "y"], at: t1)
    try fetch(store, events, ["new"], at: t1)

    XCTAssertEqual(try take(store, set, "a", at: t1), ["y"])
    XCTAssertEqual(try take(store, set, "all", at: t1), ["x", "y"])
    XCTAssertEqual(try take(store, events, "window", at: t1), ["new"], "窓の外の古い出来事は入らない")
    XCTAssertEqual(try take(store, set, "all", at: t1), ["x", "y"], "毎回すべて")
    XCTAssertEqual(
      lastRun(store, events, "window")?.dropped, AutomationDrops(), "窓の外へ出た読んだ行は捨てた数に数え直さない")
  }

  /// 古さの上限より古い、まだ受け取っていない行は捨てて、その回の記録の `dropped.expired` に数える。
  func testRowsOlderThanTheAgeLimitAreDroppedAndCounted() throws {
    let store = AutomationStore()
    let id = try define(
      store, coverage: .newArrivals,
      receivers: [receiver("a", from: .init(part: "gh", maxAgeHours: 1))])
    try fetch(store, id, ["old"], at: Self.at)
    let later = Self.at.addingTimeInterval(7200)
    try fetch(store, id, ["old", "new"], at: later)

    XCTAssertEqual(try take(store, id, "a", at: later), ["new"])
    XCTAssertEqual(lastRun(store, id, "a")?.dropped.counts, [.expired: 1])
  }

  /// 受け手が読む前に残す期間（30 日）を過ぎた出来事は、その受け手の次の回の記録の `dropped.lapsed` に数える。
  func testEventsThatLapsedBeforeBeingReadAreCounted() throws {
    let store = AutomationStore()
    let id = try define(store, coverage: .newArrivals)
    try fetch(store, id, ["old"], at: Self.at)
    let later = Self.at.addingTimeInterval(31 * Self.day)
    try fetch(store, id, ["new"], at: later)

    XCTAssertEqual(try take(store, id, "a", at: later), ["new"])
    XCTAssertEqual(lastRun(store, id, "a")?.dropped.counts, [.lapsed: 1])
    try fetch(store, id, ["newer"], at: later.addingTimeInterval(60))
    try take(store, id, "a", at: later.addingTimeInterval(60))
    XCTAssertEqual(lastRun(store, id, "a")?.dropped, AutomationDrops(), "一度数えた分は数え直さない")
  }

  // MARK: - 出す側の行

  /// 今の集合の項目は、中身が変わっても（同じ id）読んだ受け手に再び届かず、結果から消えてまた現れたら新しい項目として届く。
  /// 同じ結果を出し続けても出す側の行も変化の番号も増えない。取得が書いた余分な欄は、下流へ渡す行にそのまま載る。
  func testCurrentSetItemsKeepTheirIdentityWhileTheyStayInTheSet() throws {
    let store = AutomationStore()
    let id = try define(store, coverage: .currentSet)
    let labelled =
      #"{"id":"x","link":"https://example.com/x","body":"x","time":"2026-10-10T09:00:00Z","labels":["bug"]}"#
    func fetchText(_ lines: [String], at: Date) throws {
      try store.record(
        id, part: "gh", at: at,
        outcome: DesignSceneFixtures.fetched([]).replacing(
          lines.map {
            AutomationNodeRow(
              id: AutomationPrompts.id(of: $0) ?? "", text: $0, origin: nil, source: nil)
          }))
    }
    try fetchText([labelled], at: Self.at)
    let read = try XCTUnwrap(store.read(store.part(id, "a"), of: id, baseline: nil, now: Self.at))
    XCTAssertTrue(read.taken.first?.text.contains(#""labels":["bug"]"#) == true, "余分な欄が残る")
    try take(store, id, "a", at: Self.at)
    let seq = try store.lastSeqs(id, "gh").item

    try fetchText([labelled], at: Self.at.addingTimeInterval(60))
    XCTAssertEqual(try store.lastSeqs(id, "gh").item, seq, "同じ結果で行は増えない")
    try fetchText(
      [labelled.replacingOccurrences(of: "bug", with: "fixed")], at: Self.at.addingTimeInterval(120)
    )
    XCTAssertEqual(try take(store, id, "a", at: Self.at.addingTimeInterval(120)), [], "中身の変化は届かない")
    XCTAssertEqual(try store.lastSeqs(id, "gh").item, seq + 1, "版を足すと変化の番号が進む")

    try fetchText([], at: Self.at.addingTimeInterval(180))
    try fetchText([labelled], at: Self.at.addingTimeInterval(240))
    XCTAssertEqual(try take(store, id, "a", at: Self.at.addingTimeInterval(240)), ["x"])
  }

  /// 出来事の流れの部品が残す期間の内に同じ id を出したら、中身が違っても足さず、その回の結果の `duplicates` に数える。id が
  /// 違えば毎回届く。残す期間を過ぎた id は、指されて残っていても新しい出来事として足す。
  func testEventsWithTheSameIdWithinTheRetentionAreDuplicates() throws {
    let store = AutomationStore()
    let id = try define(store, coverage: .newArrivals)
    try fetch(store, id, ["x"], at: Self.at)
    try take(store, id, "a", at: Self.at)

    let t1 = Self.at.addingTimeInterval(60)
    try store.record(
      id, part: "gh", at: t1,
      outcome: DesignSceneFixtures.fetched([
        AutomationItem(id: "x", link: "https://example.com/x", body: "直した本文", time: t1),
        AutomationItem(id: "y", link: "https://example.com/y", body: "y", time: t1),
      ]))
    XCTAssertEqual(
      store.automation(id)?.state(key: "gh").runs.first?.run?.result,
      .fetch(fresh: 1, duplicates: 1))
    XCTAssertEqual(try take(store, id, "a", at: t1), ["y"])

    let later = Self.at.addingTimeInterval(31 * Self.day)
    try fetch(store, id, ["x"], at: later)
    XCTAssertEqual(try take(store, id, "a", at: later), ["x"], "残す期間を過ぎた id は新しい出来事")
  }

  /// 処理は出力の性質を書かなければ出来事の流れで、今の集合を書けば入力の全体を写す（入力が 0 件なら前の出力をすべて無効にする）。
  /// 性質を書き換えると今有効な項目はすべて無効になり、出来事は残る。
  func testAProcessCoverageDecidesHowItsRowsLive() throws {
    let store = AutomationStore()
    var copy = DesignSceneFixtures.agentPart(
      "copy", "写す", .arrival, from: ["gh"], instruction: "写す", coverage: .currentSet)
    copy.from = [AutomationDefinition.Input(part: "gh", take: .all)]
    let id = try define(
      store, coverage: .currentSet, receivers: [copy, receiver("a", from: .init(part: "copy"))])
    try fetch(store, id, ["x"], at: Self.at)
    try copyAll(store, id, at: Self.at)
    try copyAll(store, id, at: Self.at.addingTimeInterval(60))
    XCTAssertEqual(
      try take(store, id, "a", at: Self.at.addingTimeInterval(60)), ["x"], "読み直しても 1 度だけ")
    XCTAssertEqual(store.automation(id)?.state(key: "copy").liveLinks.count, 1)

    try fetch(store, id, [], at: Self.at.addingTimeInterval(120))
    try copyAll(store, id, at: Self.at.addingTimeInterval(120))
    XCTAssertEqual(store.automation(id)?.state(key: "copy").liveLinks, [], "入力が 0 件なら前の出力を無効にする")

    try fetch(store, id, ["y"], at: Self.at.addingTimeInterval(180))
    try copyAll(store, id, at: Self.at.addingTimeInterval(180))
    var events = try XCTUnwrap(store.automation(id)?.definition)
    events.parts[1].action.coverage = nil
    let version = try XCTUnwrap(store.automation(id)?.version)
    _ = try store.replace(id, version: version, with: events, now: Self.at.addingTimeInterval(200))
    XCTAssertEqual(store.automation(id)?.state(key: "copy").liveLinks, [], "性質を書き換えると項目は無効")
    XCTAssertEqual(
      store.automation(id)?.graph.node(key: "copy")?.coverage, .newArrivals, "書かなければ出来事の流れ")
  }

  /// 今の集合の処理が引き継いだ項目は、引き継ぎ元が変わったら（上流の項目が処理の 2 回の間に消えて現れた）別の項目になり、
  /// 下流にもう一度届く。
  func testACurrentSetProcessRowWhoseSourceChangedArrivesAgain() throws {
    let store = AutomationStore()
    var copy = DesignSceneFixtures.agentPart(
      "copy", "写す", .arrival, from: ["gh"], instruction: "写す", coverage: .currentSet)
    copy.from = [AutomationDefinition.Input(part: "gh", take: .all)]
    let id = try define(
      store, coverage: .currentSet, receivers: [copy, receiver("a", from: .init(part: "copy"))])
    try fetch(store, id, ["x"], at: Self.at)
    try copyAll(store, id, at: Self.at)
    XCTAssertEqual(try take(store, id, "a", at: Self.at), ["x"])

    try fetch(store, id, [], at: Self.at.addingTimeInterval(60))
    try fetch(store, id, ["x"], at: Self.at.addingTimeInterval(120))
    try copyAll(store, id, at: Self.at.addingTimeInterval(120))

    XCTAssertEqual(try take(store, id, "a", at: Self.at.addingTimeInterval(120)), ["x"])
    XCTAssertEqual(store.automation(id)?.state(key: "copy").liveLinks.count, 1, "今有効なのは新しい項目だけ")
  }

  /// 入力を読む部品の回は、取った行が 0 件で失敗しても、取った数（0）を記録に持つ。確定が返す回と読み直した回は同じ。
  func testARunThatReadsItsInputsKeepsItsTakenCountWhenItTookNothingAndFailed() throws {
    let store = AutomationStore()
    var copy = DesignSceneFixtures.agentPart(
      "copy", "写す", .arrival, from: ["gh"], instruction: "写す", coverage: .currentSet)
    copy.from = [AutomationDefinition.Input(part: "gh", take: .all)]
    let id = try define(
      store, coverage: .currentSet, receivers: [copy, receiver("a", from: .init(part: "copy"))])
    let part = store.part(id, "copy")
    let read = try XCTUnwrap(store.read(part, of: id, baseline: nil, now: Self.at))

    let recorded = try store.record(
      AutomationPassEnd(
        automationId: id, part: part,
        defId: try XCTUnwrap(store.automation(id)?.graph.node(part)).entity.defId,
        trigger: .arrival, startedAt: Self.at, endedAt: Self.at, read: read,
        outcome: DesignSceneFixtures.failed("boom")))

    XCTAssertEqual(recorded.run?.taken, 0)
    XCTAssertEqual(store.automation(id)?.state(key: "copy").runs.first?.run, recorded.run)
  }

  /// 上流の性質を出来事の流れから今の集合に書き換えても、受け手がまだ読んでいない出来事は届く。
  func testUnreadEventsStillArriveAfterTheUpstreamTurnsIntoASet() throws {
    let store = AutomationStore()
    let id = try define(store, coverage: .newArrivals)
    try fetch(store, id, ["x"], at: Self.at)
    var definition = try XCTUnwrap(store.automation(id)?.definition)
    definition.parts[0].action.coverage = .currentSet
    _ = try store.replace(id, version: 1, with: definition, now: Self.at)
    try fetch(store, id, ["y"], at: Self.at.addingTimeInterval(60))

    XCTAssertEqual(try take(store, id, "a", at: Self.at.addingTimeInterval(60)), ["x", "y"])
  }

  // MARK: - 失敗した回

  /// 受け手の回が失敗すると読んだ位置は進まず、次の回で同じ行がもう一度届く。失敗した回の記録にも、読んだ行と扱いは残る。
  func testAFailedReceiverReadsTheSameRowsAgainButKeepsWhatItRead() throws {
    let store = AutomationStore()
    let id = try define(store, coverage: .currentSet)
    try fetch(store, id, ["x"], at: Self.at)

    XCTAssertEqual(try take(store, id, "a", at: Self.at, failing: true), ["x"])
    XCTAssertEqual(lastRun(store, id, "a")?.taken, 1, "失敗した回も読んだ行を残す")
    try fetch(store, id, ["x", "y"], at: Self.at.addingTimeInterval(60))

    XCTAssertEqual(try take(store, id, "a", at: Self.at.addingTimeInterval(60)), ["x", "y"])
  }

  /// 回の記録の取った数は回ごとに数え、同じ部品のほかの回の分と混ざらない。
  func testEachRunCountsOnlyTheRowsItTook() throws {
    let store = AutomationStore()
    let id = try define(store, coverage: .newArrivals)
    try fetch(store, id, ["x", "y"], at: Self.at)
    try take(store, id, "a", at: Self.at)
    try fetch(store, id, ["z"], at: Self.at.addingTimeInterval(60))
    try take(store, id, "a", at: Self.at.addingTimeInterval(60))

    XCTAssertEqual(store.automation(id)?.state(key: "a").runs.map(\.run?.taken), [1, 2])
  }

  // MARK: - 写しを持たない

  /// 候補・判断・回の記録は行の中身を写して持たない（中身は出す側の行に 1 度だけある）。
  func testNothingCopiesTheContentOfARow() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(), now: Self.at).id
    let a = AutomationItem(
      id: "a", link: "https://example.com/a", body: "一度だけの本文", time: Self.at)
    try Self.fetch(store, id, [a])
    try Self.judge(store, id, proposing: [a])
    try store.dismiss(XCTUnwrap(store.proposals.first?.id), now: Self.at)

    let copies = try store.read { db in
      try db.db.select(
        """
        SELECT (SELECT count(*) FROM item_versions WHERE body LIKE '%一度だけの本文%'),
          (SELECT count(*) FROM runs WHERE record LIKE '%一度だけの本文%')
        """, []
      ) { [$0.int(at: 0), $0.int(at: 1)] }.first
    }
    XCTAssertEqual(copies, [1, 0])
    XCTAssertEqual(store.proposals.first?.item.body, "一度だけの本文", "候補の中身は出どころから引く")
  }
}

extension AutomationNodePass.Outcome {
  /// 取得の回の出力を、書かれたままの行に差し替えたもの（テスト）。
  fileprivate func replacing(_ rows: [AutomationNodeRow]) -> Self {
    guard case .succeeded(_, let execution, let breach) = self else { return self }
    return .succeeded(.fetch(rows), execution, breach: breach)
  }
}
