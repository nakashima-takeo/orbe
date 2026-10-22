import OrbeTestSupport
import XCTest

@testable import Orbe

/// 自動化のストアの保存——再起動の往復、DB の版と形の確かめ、読めない定義・記録の閉じ込め、2 つ目の Orbe の締め出し、
/// 回の記録と判断の記録の保持。DB は caseDir の本物。
///
/// 壊れると何が起きるか: 再起動で読んだ位置・候補・回の記録・決まりを外した印が巻き戻るか消える。古い版の DB や形の違う DB で
/// 起動が落ちる、または読み違える。新しい版の DB を退避して利用者の自動化を失う。読めない定義が 1 つあるだけで全部の自動化を
/// 失う。同じ state の 2 つ目の Orbe が予定を回して副作用を二重に起こす。回の記録が際限なく溜まる、または候補・目印・外した印が
/// 指す回を消して読めなくなる。
final class AutomationStoreTests: OrbeTestCase {
  static let at = Date(timeIntervalSince1970: 1_800_000_000)

  /// 取得の部品 `fetch` と、届いたらタスク候補を出す判定の部品 `judge`。
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
    try store.record(
      id, part: "fetch", at: at, outcome: outcome ?? DesignSceneFixtures.fetched(items))
  }

  /// 判定の部品の、読める行をすべて取った回を確定する。案の出どころは、取った行のうち同じ書かれた id の行のもの。候補にした
  /// 理由は `reason`（省けば無し）。
  static func judge(
    _ store: AutomationStore, _ id: Int, proposing items: [AutomationItem] = [],
    resolving links: [String] = [], reason: String? = nil, at: Date = at
  ) throws {
    let taken = try XCTUnwrap(
      store.read(store.part(id, "judge"), of: id, baseline: nil, now: at)
    ).taken
    let proposals = items.compactMap { item -> AutomationPartPass.Proposal? in
      taken.first { $0.origin?.item.id == item.id }?.origin.map {
        AutomationPartPass.Proposal(
          origin: $0, title: "対応: \(item.id)", due: nil, workspace: nil, reason: reason)
      }
    }
    try store.record(
      id, part: "judge", trigger: .arrival, at: at,
      outcome: .succeeded(
        .judge(proposals: proposals, resolved: links), DesignSceneFixtures.execution(taken.count),
        breach: nil))
  }

  /// 今の版で書き換える。同じ鍵の部品は今の部品の id を添える（同じ部品のまま）。
  @discardableResult static func rewrite(
    _ store: AutomationStore, _ id: Int, _ definition: AutomationDefinition, at: Date = at
  ) throws -> AutomationStore.Replaced {
    let current = try XCTUnwrap(store.automation(id))
    var definition = definition
    for index in definition.parts.indices {
      definition.parts[index].id = current.graph.node(key: definition.parts[index].key)?.id
    }
    return try store.replace(id, version: current.version, with: definition, now: at)
  }

  /// 断った結果をその場で直して通った取得の回。
  static func breached(_ items: [AutomationItem]) -> AutomationPartPass.Outcome {
    let fetched = DesignSceneFixtures.fetched(items)
    guard case .succeeded(let output, let execution, _) = fetched else {
      preconditionFailure("a fetched outcome succeeds")
    }
    return .succeeded(
      output, execution,
      breach: AutomationRejections([AutomationBrokenLine(line: 3, fault: .missingKey("link"))]))
  }

  func quarantined() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: TestScratch.caseDir.path)
      .filter { $0.hasPrefix("automations-broken-") }
  }

  /// DB のファイル（ストアを閉じてから触る）。
  func database() throws -> SQLiteDatabase {
    try SQLiteDatabase(url: automationsFolder().appendingPathComponent("db.sqlite"))
  }

  /// メモリだけの変化の番号を除いた自動化（開き直すと 0 から数え直す）。
  static func persisted(_ automations: [Automation]?) -> [Automation]? {
    automations?.map { automation in
      var automation = automation
      for id in automation.parts.keys { automation.parts[id]?.changes = 0 }
      return automation
    }
  }

  // MARK: - 再起動

  /// 自動化・つながりの取り方（take・古さの上限）・部品の状態（読んだ位置・今有効な項目・決まりを外した印・回の記録・持ち越し・
  /// 読めば取る行の数）・版・候補は、どの変異（作る・確定・書き換え・さばく・止める・消す）の後に開き直しても同じ。回の記録は
  /// 失敗・判定の確定で捨てた案も、候補は候補にした理由も同じ。
  func testEverythingSurvivesARestart() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    let (a, b) = (Self.item("a"), Self.item("b"))
    try Self.fetch(XCTUnwrap(store), id, [a], outcome: Self.breached([a]))
    try Self.judge(
      XCTUnwrap(store), id, proposing: [a], resolving: ["https://example.com/gone"],
      reason: "レビューを頼まれている。")
    try Self.fetch(XCTUnwrap(store), id, [a, b], at: Self.at.addingTimeInterval(1800))
    try Self.fetch(
      XCTUnwrap(store), id, [],
      outcome: DesignSceneFixtures.failed(.reported("rate limited"), ending: .exited(0)),
      at: Self.at.addingTimeInterval(3600))
    var rewritten = Self.definition("受信（要約つき）")
    rewritten.notify = .menuBar
    var digest = DesignSceneFixtures.commandPart(
      "digest", "要約", .arrival, from: ["fetch"], script: "digest", deliver: .report)
    digest.from = [AutomationDefinition.Input(part: "fetch", take: .all, maxAgeHours: 24)]
    rewritten.parts.append(digest)
    try Self.rewrite(XCTUnwrap(store), id, rewritten)
    try store?.dismiss(XCTUnwrap(store?.proposals.first?.id), now: Self.at)
    _ = try store?.setPaused(id, true, now: Self.at)
    let deleted = try XCTUnwrap(store?.create(Self.definition("消す"), now: Self.at).id)
    try store?.delete(deleted, now: Self.at)
    let automations = store?.automations
    let proposals = store?.proposals
    XCTAssertEqual(automations?.first?.state(key: "judge").inbox, 1, "前提: 判定が読めば取る行がある")
    XCTAssertEqual(automations?.first?.version, 2)
    store = nil

    let reopened = AutomationStore()

    XCTAssertEqual(reopened.automations, Self.persisted(automations))
    XCTAssertEqual(reopened.proposals, proposals)
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
    func mark() -> AutomationBreachMark? { store.automation(id)?.state(key: "fetch").breach }

    XCTAssertEqual(
      mark(),
      AutomationBreachMark(
        at: Self.at,
        lines: AutomationRejections(
          count: 1, lines: [AutomationBrokenLine(line: 3, fault: .missingKey("link"))]),
        passed: true))
    try Self.rewrite(store, id, Self.definition("改名"))
    XCTAssertEqual(mark()?.at, Self.at, "名前だけなら残る")
    try Self.rewrite(store, id, Self.definition("改名", script: "fetch --all"))
    XCTAssertNil(mark(), "何をするかが変われば下ろす")
  }

  // MARK: - 書き込みの 1 経路

  /// 変異のトランザクションが通らなければ、メモリも DB も変わらず、呼び手に「保存できない」を返す（ストアは使えるまま）。
  func testAMutationThatFailsToCommitChangesNeitherMemoryNorTheDatabase() throws {
    struct Refused: Error {}
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)

    func deleteThenFail(_ db: AutomationDatabase, _ memory: inout AutomationMemory) throws {
      try db.setPaused(id, at: Self.at)
      memory.automations.removeAll()
      throw Refused()
    }

    XCTAssertThrowsError(try store?.commit(sweepingAt: nil, deleteThenFail)) {
      guard case .unavailable = $0 as? AutomationError else { return XCTFail("\($0)") }
    }

    XCTAssertEqual(store?.automations.map(\.id), [id])
    XCTAssertEqual(store?.available, true)
    store = nil
    XCTAssertEqual(AutomationStore().automation(id)?.paused, false, "DB も巻き戻っている")
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
    try store?.delete(deleted, now: Self.at)
    XCTAssertEqual(store?.proposals, [], "前提: 消した自動化だけが持っていた候補は下がる")
    store = nil

    let reopened = AutomationStore()
    let created = try reopened.create(Self.definition("新しい"), now: Self.at).id
    try Self.fetch(reopened, kept, [x])
    try Self.judge(reopened, kept, proposing: [x])

    XCTAssertGreaterThan(created, deleted)
    XCTAssertGreaterThan(try XCTUnwrap(reopened.proposals.first?.id), forgotten)
  }

  /// 回の記録は部品ごとに新しい 20 件を残し、それより古い回は消える。ただし最新の成功した回・外した印の回・残っている候補を
  /// 出した回は消えない。開き直しても同じ。
  func testOldRunsAreSweptExceptTheOnesSomethingPointsAt() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    let a = Self.item("a")
    try Self.fetch(XCTUnwrap(store), id, [a], outcome: Self.breached([a]))
    try Self.judge(XCTUnwrap(store), id, proposing: [a])
    let count = AutomationPartState.retainedRuns + 3
    for n in 1...count {
      try Self.fetch(
        XCTUnwrap(store), id, [], outcome: DesignSceneFixtures.failed("boom"),
        at: Self.at.addingTimeInterval(TimeInterval(60 * n)))
      try Self.judge(XCTUnwrap(store), id, at: Self.at.addingTimeInterval(TimeInterval(60 * n)))
    }
    let fetches = try XCTUnwrap(store?.automation(id)?.state(key: "fetch"))
    store = nil
    let kept = try database().select(
      """
      SELECT r.started_at FROM runs r JOIN parts p ON p.id = r.part_id WHERE p.key = 'fetch'
      ORDER BY r.id
      """, []
    ) { AutomationPersistence.date($0.int64(at: 0)) }
    let judged = try database().select(
      "SELECT count(*) FROM runs r JOIN parts p ON p.id = r.part_id WHERE p.key = 'judge'", []
    ) { $0.int(at: 0) }.first

    XCTAssertEqual(fetches.runs.count, AutomationPartState.retainedRuns)
    XCTAssertEqual(
      kept,
      [Self.at] + (4...count).map { Self.at.addingTimeInterval(TimeInterval(60 * $0)) },
      "外した印の回で、最新の成功した回でもある最初の回は残る")
    XCTAssertEqual(fetches.succeededAt, Self.at)
    XCTAssertEqual(fetches.breach?.at, Self.at)
    XCTAssertEqual(
      judged, AutomationPartState.retainedRuns + 1, "候補を出した回は 20 件の外でも残る")
    XCTAssertEqual(AutomationStore().automation(id)?.state(key: "fetch").runs, fetches.runs)
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

  // MARK: - 判断の記録

  /// 人が候補をタスクにする・捨てるたびに判断が 1 件残り、候補が Orbe に忘れられた後も残る。判断は、候補を出した判定の回が
  /// 動いた定義ごとに分かれる（指示文を書き換えた後の候補への判断は、前の候補への判断と別の定義に数える）。
  func testEachDecisionIsKeptAndCountedByTheDefinitionThatProposed() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    let (a, b) = (Self.item("a"), Self.item("b"))
    try Self.fetch(XCTUnwrap(store), id, [a])
    try Self.judge(XCTUnwrap(store), id, proposing: [a])
    var rewritten = Self.definition()
    rewritten.parts[1] = DesignSceneFixtures.agentPart(
      "judge", "判定", .arrival, from: ["fetch"], model: "sonnet", instruction: "別の基準で選ぶ。",
      deliver: .taskCandidates)
    try Self.rewrite(XCTUnwrap(store), id, rewritten)
    try Self.fetch(XCTUnwrap(store), id, [a, b])
    try Self.judge(XCTUnwrap(store), id, proposing: [b])
    let proposals = try XCTUnwrap(store?.proposals)
    XCTAssertNotEqual(proposals[0].defId, proposals[1].defId, "前提: 別の定義が出した")
    try store?.dismiss(proposals[0].id, now: Self.at)
    try store?.dismiss(proposals[1].id, now: Self.at)
    try Self.fetch(XCTUnwrap(store), id, [])
    XCTAssertEqual(store?.proposals, [], "前提: 取得から消えて忘れた")
    store = nil

    let decided = try database().select(
      """
      SELECT r.def_id, s.outcome FROM settlements s JOIN proposals q ON q.id = s.proposal_id
      JOIN runs r ON r.id = q.run_id ORDER BY s.proposal_id
      """, []
    ) { "\($0.int(at: 0)) \($0.text(at: 1) ?? "")" }

    XCTAssertEqual(
      decided,
      [
        "\(proposals[0].defId.rawValue) dismissed", "\(proposals[1].defId.rawValue) dismissed",
      ])
  }
}
