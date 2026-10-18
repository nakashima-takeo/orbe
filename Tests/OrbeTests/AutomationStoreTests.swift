import OrbeTestSupport
import XCTest

@testable import Orbe

/// 自動化のストアの保存——再起動の往復、旧形式の JSON と読めない DB の退避、2 つ目の Orbe の締め出し。DB は caseDir の本物。
///
/// 壊れると何が起きるか: 再起動で溜まり・候補・回の記録・決まりを外した印が巻き戻るか消える。旧形式の自動化を抱えた環境で
/// 起動できない、または古い定義を読み違える。Orbe が書いたのではない DB で起動が落ちる。同じ state の 2 つ目の Orbe が予定を
/// 回して副作用を二重に起こす、先に開いた Orbe の DB を退避して中身を奪う。
final class AutomationStoreTests: OrbeTestCase {
  static let at = Date(timeIntervalSince1970: 1_800_000_000)

  /// 今の集合を取る取得の部品 `fetch` と、届いたらタスク候補を出す判定の部品 `judge`。
  static func definition(
    _ name: String = "受信", coverage: AutomationCoverage = .currentSet, script: String = "fetch"
  ) -> AutomationDefinition {
    DesignSceneFixtures.candidatesDefinition(
      name,
      fetch: DesignSceneFixtures.commandPart(
        "fetch", "取る", .scheduled(.every(1800)), script: script, coverage: coverage))
  }

  static func item(_ id: String) -> AutomationItem {
    AutomationItem(id: id, link: "https://example.com/\(id)", body: "\(id) の本文", time: at)
  }

  /// 取得の部品の回を確定する。
  static func fetch(
    _ store: AutomationStore, _ id: Int, _ items: [AutomationItem],
    outcome: AutomationPartPass.Outcome? = nil, at: Date = at
  ) throws {
    _ = try store.record(
      AutomationPassEnd(
        automationId: id, part: "fetch", trigger: .schedule, startedAt: at, endedAt: at,
        take: nil, outcome: outcome ?? DesignSceneFixtures.fetched("fetch", items)))
  }

  /// 判定の部品の、溜まりをすべて取った回を確定する。
  static func judge(
    _ store: AutomationStore, _ id: Int, proposing items: [AutomationItem] = [],
    resolving links: [String] = [], at: Date = at
  ) throws {
    let taken = try store.inbox(of: "judge", in: id).map(\.seq)
    _ = try store.record(
      AutomationPassEnd(
        automationId: id, part: "judge", trigger: .arrival, startedAt: at, endedAt: at,
        take: AutomationInbox.Take(taken: taken, dropped: []),
        outcome: .succeeded(
          .judge(
            proposals: items.map { DesignSceneFixtures.proposal($0, "対応: \($0.id)") },
            resolved: links),
          DesignSceneFixtures.execution(taken.count), breach: nil)))
  }

  /// 決まりを外した取得の回（出し直しで通った）。
  static func breached(_ items: [AutomationItem]) -> AutomationPartPass.Outcome {
    let fetched = DesignSceneFixtures.fetched("fetch", items)
    guard case .succeeded(let output, let execution, _) = fetched else {
      preconditionFailure("a fetched outcome succeeds")
    }
    return .succeeded(
      output, execution,
      breach: AutomationPartPass.Breach(
        lines: [AutomationBrokenLine(line: 3, fault: .missingKey("link"))],
        redo: AutomationPartPass.Redo(firstCall: execution, lines: [])))
  }

  private func quarantined() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: TestScratch.caseDir.path)
      .filter { $0.hasPrefix("automations-broken-") }
  }

  // MARK: - 再起動

  /// 自動化・部品の状態（前回の出力・決まりを外した印・回の記録・溜まり）・候補は、どの変異（作る・確定・書き換え・さばく・
  /// 止める・消す）の後に開き直しても同じで、溜まりの行も同じ本文で読める。
  func testEverythingSurvivesARestart() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    let (a, b) = (Self.item("a"), Self.item("b"))
    try Self.fetch(XCTUnwrap(store), id, [a], outcome: Self.breached([a]))
    try Self.judge(XCTUnwrap(store), id, proposing: [a])
    try Self.fetch(XCTUnwrap(store), id, [a, b], at: Self.at.addingTimeInterval(1800))
    var rewritten = Self.definition("受信（要約つき）")
    rewritten.notify = .menuBar
    rewritten.parts.append(
      DesignSceneFixtures.commandPart(
        "digest", "要約", .arrival, from: ["fetch"], script: "digest", deliver: .report))
    _ = try store?.replace(id, with: rewritten, now: Self.at)
    try store?.dismiss(XCTUnwrap(store?.proposals.first?.id))
    _ = try store?.setPaused(id, true)
    let deleted = try XCTUnwrap(store?.create(Self.definition("消す"), now: Self.at).id)
    try store?.delete(deleted)
    let automations = store?.automations
    let proposals = store?.proposals
    let rows = try store?.rows(XCTUnwrap(store?.inbox(of: "judge", in: id)).map(\.seq))
    XCTAssertEqual(rows?.isEmpty, false, "前提: 溜まりに行がある")
    store = nil

    let reopened = AutomationStore()

    XCTAssertEqual(reopened.automations, automations)
    XCTAssertEqual(reopened.proposals, proposals)
    XCTAssertEqual(try reopened.rows(reopened.inbox(of: "judge", in: id).map(\.seq)), rows)
  }

  // MARK: - 退避

  /// 旧形式の `automations.json` は退避して読まず、自動化 0 件で使える状態で始まる。
  func testALegacyFileIsSetAsideAndAutomationsStartEmpty() throws {
    let legacy = try XCTUnwrap(AutomationPersistence.legacyFile)
    let original = Data(#"{"version":3,"automations":[{"id":1,"name":"旧"}]}"#.utf8)
    try original.write(to: legacy)

    let store = AutomationStore()

    XCTAssertTrue(store.available)
    XCTAssertEqual(store.automations, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    let aside = try quarantined().filter { $0.hasSuffix(".json") }
    XCTAssertEqual(aside.count, 1)
    let moved = legacy.deletingLastPathComponent().appendingPathComponent(
      try XCTUnwrap(aside.first))
    XCTAssertEqual(try Data(contentsOf: moved), original)
  }

  /// 今の形として読めない行を持つ DB（Orbe が書いたのではない）は、フォルダごと退避して空で始まる。読める JSON でも、グラフの
  /// 検証を通らない定義は読めない行。
  func testADatabaseWithRowsOrbeCannotReadIsSetAsideAndStartsEmpty() throws {
    _ = try AutomationStore().create(Self.definition(), now: Self.at)
    var invalid = Self.definition()
    invalid.parts[1] = DesignSceneFixtures.agentPart(
      "judge", "判定", .arrival, from: ["fetch"], tools: ["Read"], instruction: "判定する",
      deliver: .taskCandidates)
    XCTAssertThrowsError(try invalid.checked(), "前提: 検証を通らない定義")
    try SQLiteDatabase(url: automationsFolder().appendingPathComponent("db.sqlite")).run(
      "UPDATE automations SET definition = ?", [.text(try AutomationDatabase.encode(invalid))])

    let store = AutomationStore()

    XCTAssertTrue(store.available)
    XCTAssertEqual(store.automations, [])
    XCTAssertEqual(try quarantined().count, 1)
  }

  // MARK: - 排他

  /// 先に開いたストアが DB を持つ間、同じ DB を開く 2 つ目のストアは読まず・書かず・退避もしない。先のストアが手放せば開ける。
  func testASecondStoreOnTheSameDatabaseNeitherReadsNorWritesNorSetsItAside() throws {
    var first: AutomationStore? = AutomationStore()
    _ = try first?.create(Self.definition("一つ目"), now: Self.at)

    var second: AutomationStore? = AutomationStore()

    XCTAssertEqual(second?.available, false)
    XCTAssertEqual(second?.automations, [])
    XCTAssertThrowsError(try second?.create(Self.definition("二つ目"), now: Self.at)) {
      guard case .unavailable = $0 as? AutomationError else { return XCTFail("\($0)") }
    }
    _ = try first?.create(Self.definition("三つ目"), now: Self.at)
    XCTAssertEqual(try quarantined(), [], "先のストアの DB を退避しない")

    second = nil
    first = nil
    XCTAssertEqual(AutomationStore().automations.map(\.name), ["一つ目", "三つ目"])
  }

  // MARK: - 決まりを外した印

  /// 出力が決まりを外した印は最初の回に付き、何をするかが変わるまで残る（名前だけの書き換えでは残る）。
  func testTheBreachMarkStaysFromTheFirstBreachUntilThePartsWorkChanges() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(), now: Self.at).id
    let a = Self.item("a")
    try Self.fetch(store, id, [a], outcome: Self.breached([a]))
    try Self.fetch(store, id, [a], outcome: Self.breached([a]), at: Self.at.addingTimeInterval(60))
    func mark() -> AutomationBreachMark? { store.automation(id)?.state("fetch").breach }

    XCTAssertEqual(
      mark(),
      AutomationBreachMark(
        at: Self.at,
        lines: AutomationRejections(
          count: 1, lines: [AutomationBrokenLine(line: 3, fault: .missingKey("link"))]),
        redone: true, passed: true))
    _ = try store.replace(id, with: Self.definition("改名"), now: Self.at)
    XCTAssertEqual(mark()?.at, Self.at, "名前だけなら残る")
    _ = try store.replace(id, with: Self.definition("改名", script: "fetch --all"), now: Self.at)
    XCTAssertNil(mark(), "何をするかが変われば下ろす")
  }

  // MARK: - 溜まりの上限

  /// 溜まりの件数の上限を超えて捨てた行は、その部品の次の回の記録に数える。
  func testRowsDroppedOverTheInboxLimitAreCountedInTheNextRun() throws {
    let store = AutomationStore()
    var definition = Self.definition()
    definition.parts[1].inboxLimit = AutomationPart.InboxLimit(maxAgeHours: nil, maxItems: 2)
    let id = try store.create(definition, now: Self.at).id
    try Self.fetch(store, id, ["a", "b", "c"].map(Self.item))
    XCTAssertEqual(store.automation(id)?.state("judge").inbox, 2)

    try Self.judge(store, id)

    XCTAssertEqual(store.automation(id)?.state("judge").runs.first?.dropped.counts, [.overflow: 1])
  }

  // MARK: - 書き込みの 1 経路

  /// 変異のトランザクションが通らなければ、メモリも DB も変わらず、呼び手に「保存できない」を返す（ストアは使えるまま）。
  func testAMutationThatFailsToCommitChangesNeitherMemoryNorTheDatabase() throws {
    struct Refused: Error {}
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)

    func deleteThenFail(_ db: AutomationDatabase, _ memory: inout AutomationMemory) throws {
      try db.delete(automation: id)
      memory.automations.removeAll()
      throw Refused()
    }

    XCTAssertThrowsError(try store?.commit(deleteThenFail)) {
      guard case .unavailable = $0 as? AutomationError else { return XCTFail("\($0)") }
    }

    XCTAssertEqual(store?.automations.map(\.id), [id])
    XCTAssertEqual(store?.available, true)
    store = nil
    XCTAssertEqual(AutomationStore().automations.map(\.id), [id], "DB も巻き戻っている")
  }

  // MARK: - ID と記録

  /// 消した自動化と忘れた候補の ID は、開き直しても使い回さない。
  func testIdsOfDeletedAutomationsAndForgottenProposalsAreNeverReused() throws {
    var store: AutomationStore? = AutomationStore()
    let kept = try XCTUnwrap(store?.create(Self.definition("残す"), now: Self.at).id)
    let deleted = try XCTUnwrap(store?.create(Self.definition("消す"), now: Self.at).id)
    let x = Self.item("x")
    try Self.fetch(XCTUnwrap(store), deleted, [x])
    try Self.judge(XCTUnwrap(store), deleted, proposing: [x])
    let forgotten = try XCTUnwrap(store?.proposals.first?.id)
    try store?.delete(deleted)
    XCTAssertEqual(store?.proposals, [], "前提: 消した自動化だけが持っていた候補は忘れる")
    store = nil

    let reopened = AutomationStore()
    let created = try reopened.create(Self.definition("新しい"), now: Self.at).id
    try Self.fetch(reopened, kept, [x])
    try Self.judge(reopened, kept, proposing: [x])

    XCTAssertGreaterThan(created, deleted)
    XCTAssertGreaterThan(try XCTUnwrap(reopened.proposals.first?.id), forgotten)
  }

  /// 回の記録は部品ごとに新しい 20 件だけを残し、開き直しても同じ 20 件。
  func testOnlyTheNewestRunsOfAPartAreKeptAcrossARestart() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    let count = AutomationPartState.retainedRuns + 3
    for n in 0..<count {
      try Self.fetch(XCTUnwrap(store), id, [], at: Self.at.addingTimeInterval(TimeInterval(60 * n)))
    }
    let runs = try XCTUnwrap(store?.automation(id)?.state("fetch").runs)
    XCTAssertEqual(
      runs.map(\.startedAt),
      (3..<count).reversed().map { Self.at.addingTimeInterval(TimeInterval(60 * $0)) })
    store = nil

    XCTAssertEqual(AutomationStore().automation(id)?.state("fetch").runs, runs)
  }

  // MARK: - 定義

  /// 自動化の名前は前後の空白を除いて 1 行で保存し、空や複数行の名前は断る。
  func testTheNameIsKeptOnOneTrimmedLine() throws {
    let store = AutomationStore()
    XCTAssertEqual(try store.create(Self.definition("  受信  "), now: Self.at).name, "受信")
    for name in ["受信\n2 行目", "   "] {
      XCTAssertThrowsError(try store.create(Self.definition(name), now: Self.at), name) {
        guard case .invalid = $0 as? AutomationError else { return XCTFail("\($0)") }
      }
    }
    XCTAssertEqual(store.automations.count, 1)
  }

  // MARK: - 累計

  /// さばいた候補は、棚に出していた自動化でなく出した自動化の累計に数え、開き直しても残る。判定の部品が無くなれば 0 に戻る。
  func testHandlingAProposalCountsOnTheAutomationThatProposedIt() throws {
    var store: AutomationStore? = AutomationStore()
    let issuer = try XCTUnwrap(store?.create(Self.definition("出した"), now: Self.at).id)
    let shelf = try XCTUnwrap(store?.create(Self.definition("棚"), now: Self.at).id)
    let a = Self.item("a")
    try Self.fetch(XCTUnwrap(store), issuer, [a])
    try Self.judge(XCTUnwrap(store), issuer, proposing: [a])
    try Self.fetch(XCTUnwrap(store), shelf, [a])
    try Self.fetch(XCTUnwrap(store), issuer, [])
    let proposal = try XCTUnwrap(store?.proposals.first)
    XCTAssertEqual(store?.shelf(of: proposal)?.id, shelf, "前提: 棚は別の自動化")

    try store?.dismiss(proposal.id)
    store = nil
    let reopened = AutomationStore()

    XCTAssertEqual(reopened.automation(issuer)?.tally, AutomationTally(accepted: 0, dismissed: 1))
    XCTAssertEqual(reopened.automation(shelf)?.tally, AutomationTally())
    _ = try reopened.replace(
      issuer,
      with: AutomationDefinition(
        name: "出した", notify: nil,
        parts: [
          Self.definition().parts[0],
          DesignSceneFixtures.commandPart(
            "digest", "要約", .arrival, from: ["fetch"], script: "digest", deliver: .report),
        ]), now: Self.at)
    XCTAssertEqual(reopened.automation(issuer)?.tally, AutomationTally())
  }
}
