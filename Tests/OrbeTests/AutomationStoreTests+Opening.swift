import XCTest

@testable import Orbe

/// 開くとき——DB の版の確かめ、読めない定義・記録の閉じ込め。
///
/// 壊れると何が起きるか: 古い版の DB で起動が落ちる、または読み違える。新しい版の DB を退避して利用者の自動化を
/// 失う。読めない定義が 1 つあるだけで全部の自動化を失う。読めない記録 1 件で部品の記録が全部消える。
extension AutomationStoreTests {
  // MARK: - 版

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

  /// 版 1 の DB（移行は無い）はフォルダごと退避し、自動化 0 件で始まる。
  func testAVersionOneDatabaseIsSetAsideAndStartsEmpty() throws {
    try FileManager.default.createDirectory(
      at: automationsFolder(), withIntermediateDirectories: true)
    try database().exec("CREATE TABLE automations (id INTEGER); PRAGMA user_version = 1")

    let store = AutomationStore()

    XCTAssertTrue(store.available)
    XCTAssertEqual(store.automations, [])
    XCTAssertEqual(try quarantined().count, 1)
  }

  /// 今より新しい版の DB は動かさずに使わず、変異も一覧も理由を言って断る。
  func testANewerDatabaseIsLeftAloneAndAutomationsAreRefusedWithTheReason() throws {
    _ = try AutomationStore().create(Self.definition(), now: Self.at)
    try database().exec("PRAGMA user_version = 99")

    let store = AutomationStore()

    XCTAssertFalse(store.available)
    XCTAssertEqual(try quarantined(), [], "新しい版は退避しない")
    XCTAssertThrowsError(try store.create(Self.definition(), now: Self.at)) {
      guard case .unavailable(let reason) = $0 as? AutomationError else { return XCTFail("\($0)") }
      XCTAssertTrue(reason.contains("version 99"), reason)
    }
  }

  // MARK: - 閉じ込め

  /// 版 2 の DB で組み合わせの部品の定義を指す部品は壊れた値なので、その自動化は定義エラーとして読めない自動化になる。
  func testANodePointingAtACompositeDefinitionIsADefinitionError() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    let judge = try XCTUnwrap(store?.nodeId(id, "judge"))
    store = nil
    try database().exec(
      """
      INSERT INTO node_defs (kind) VALUES ('composite');
      INSERT INTO composite_defs (id) VALUES (last_insert_rowid());
      UPDATE nodes SET def_id = (SELECT max(id) FROM composite_defs) WHERE id = \(judge.rawValue);
      """)

    let reopened = AutomationStore()

    XCTAssertEqual(reopened.automations, [])
    XCTAssertEqual(
      reopened.unreadable.first?.reason,
      "nodes[1]: the stored definition is made of nodes, which this database version does not hold")
  }

  /// 動作の定義の JSON を壊した自動化は、その自動化だけが「定義を読めない」として残る（組めた定義・版・理由を持ち、動かず、
  /// 持っていた候補はほかの自動化の確定の後も消えない）。版を添えた書き換えで直り、消すこともできる。ほかの自動化は普段どおり。
  func testAnAutomationWhoseDefinitionCannotBeReadStaysAsideAlone() throws {
    var store: AutomationStore? = AutomationStore()
    let broken = try XCTUnwrap(store?.create(Self.definition("壊す"), now: Self.at).id)
    let fine = try XCTUnwrap(store?.create(Self.definition("普段"), now: Self.at).id)
    let a = Self.item("a")
    try Self.fetch(XCTUnwrap(store), broken, [a])
    try Self.judge(XCTUnwrap(store), broken, proposing: [a])
    let judge = try XCTUnwrap(store?.nodeId(broken, "judge"))
    store = nil
    try database().run(
      """
      UPDATE action_defs SET action = '{"instruction": 1}'
      WHERE id = (SELECT def_id FROM nodes WHERE id = ?)
      """, [.integer(Int64(judge.rawValue))])

    let reopened = AutomationStore()

    XCTAssertEqual(reopened.automations.map(\.id), [fine])
    let aside = try XCTUnwrap(reopened.unreadable.first)
    XCTAssertEqual(aside.id, broken)
    XCTAssertEqual(aside.name, "壊す")
    XCTAssertEqual(aside.version, 1)
    XCTAssertTrue(aside.reason.hasPrefix("invalid nodes[1].instruction"), aside.reason)
    XCTAssertTrue(aside.definition.contains(#""key":"judge""#), aside.definition)
    XCTAssertEqual(reopened.proposals.map(\.item.link), [a.link], "持っていた候補は残る")
    try Self.fetch(reopened, fine, [])
    XCTAssertEqual(reopened.proposals.map(\.item.link), [a.link], "ほかの確定の後も残る")
    XCTAssertThrowsError(try reopened.setPaused(broken, true, now: Self.at)) {
      guard case .unreadable(broken, _) = $0 as? AutomationError else { return XCTFail("\($0)") }
    }

    var fixed = Self.definition("直した")
    fixed.nodes[0].id = reopened.unreadable.first?.nodeIds.first
    fixed.nodes[1].id = judge
    let replaced = try reopened.replace(broken, version: 1, with: fixed, now: Self.at)

    XCTAssertEqual(reopened.unreadable, [])
    XCTAssertEqual(reopened.automations.map(\.id), [broken, fine])
    XCTAssertEqual(replaced.automation.version, 2)
    XCTAssertEqual(Set(replaced.reworked), Set(fixed.nodes.compactMap(\.id)))
    try reopened.delete(broken, now: Self.at)
    XCTAssertEqual(reopened.automations.map(\.id), [fine])
  }

  /// 判定の動作の定義を壊した、取得に決まりを外した印のある自動化（読めない自動化として開き直したストア）。
  private func unreadableWithABreach() throws -> (store: AutomationStore, id: Int) {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition("壊す"), now: Self.at).id)
    try Self.fetch(XCTUnwrap(store), id, [Self.item("a")], outcome: Self.breached([Self.item("a")]))
    let judge = try XCTUnwrap(store?.nodeId(id, "judge"))
    store = nil
    try database().run(
      """
      UPDATE action_defs SET action = '{"instruction": 1}'
      WHERE id = (SELECT def_id FROM nodes WHERE id = ?)
      """, [.integer(Int64(judge.rawValue))])
    return (AutomationStore(), id)
  }

  /// 読めない自動化を直すと、残る部品は開き直したストアと同じ状態（回の記録・通し番号・足した時刻）から続き、何をするかが
  /// 変わったものとして外した印が下りる。今の集合のまま直した部品の今有効な項目は残る。
  func testFixingAnUnreadableAutomationCarriesItsNodesOverAndLowersTheirMarks() throws {
    let (carried, id) = try { () throws -> (Automation, Int) in
      let (store, id) = try unreadableWithABreach()
      var fixed = Self.definition("直した")
      for index in fixed.nodes.indices {
        fixed.nodes[index].id = store.unreadable.first?.nodeIds[index]
      }

      _ = try store.replace(id, version: 1, with: fixed, now: Self.at)

      return (try XCTUnwrap(store.automation(id)), id)
    }()

    XCTAssertEqual(carried.state(key: "fetch").runs.count, 1)
    XCTAssertNil(carried.state(key: "fetch").breach)
    XCTAssertEqual(
      carried.state(key: "fetch").liveLinks, [Self.item("a").link], "今の集合のままなら項目は残る")
    XCTAssertEqual(carried, AutomationStore().automation(id))
  }

  /// 読めない自動化を、今の集合の部品の出力の性質を変えて直すと、その部品の今有効な項目は無効になる。
  func testFixingAnUnreadableAutomationWithAnotherCoverageInvalidatesItsItems() throws {
    let (store, id) = try unreadableWithABreach()
    var fixed = Self.definition("直した", coverage: .newArrivals)
    for index in fixed.nodes.indices {
      fixed.nodes[index].id = store.unreadable.first?.nodeIds[index]
    }

    _ = try store.replace(id, version: 1, with: fixed, now: Self.at)

    XCTAssertEqual(store.automation(id)?.state(key: "fetch").liveLinks, [])
  }

  /// 読めない自動化の書き換えでも、id を落として今の部品と同じ鍵で書いた部品は断り、部品は変わらない。
  func testAnUnreadableAutomationRefusesARewriteThatDropsTheNodeIds() throws {
    let (store, id) = try unreadableWithABreach()
    let nodeIds = store.unreadable.first?.nodeIds

    XCTAssertThrowsError(try store.replace(id, version: 1, with: Self.definition(), now: Self.at)) {
      guard case .invalid(let message) = $0 as? AutomationError else { return XCTFail("\($0)") }
      XCTAssertTrue(message.hasPrefix(#"nodes[0].id: the key "fetch" belongs to node"#), message)
    }
    XCTAssertEqual(store.unreadable.first?.nodeIds, nodeIds)
  }

  /// 値の壊れた候補は、その 1 件だけが読めない候補としてリンクを塞ぎ続け、持ち主（出した判定の部品の自動化）が無くなれば
  /// メモリからも DB からも忘れる。
  func testAProposalThatCannotBeReadHoldsItsLinkUntilItsHolderIsGone() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(coverage: .newArrivals), now: Self.at).id)
    let (a, b) = (Self.item("a"), Self.item("b"))
    try Self.fetch(XCTUnwrap(store), id, [a, b])
    try Self.judge(XCTUnwrap(store), id, proposing: [a, b])
    store = nil
    try database().run("UPDATE proposals SET due = 'x' WHERE link = ?", [.text(a.link)])

    let reopened = AutomationStore()
    XCTAssertEqual(reopened.proposals.map(\.item.link), [b.link], "ほかの候補は普段どおり")
    XCTAssertEqual(reopened.unreadableProposals.map(\.link), [a.link])
    XCTAssertTrue(reopened.heldLinks.contains(a.link), "読めない候補も同じリンクを塞ぐ")

    try reopened.delete(id, now: Self.at)

    XCTAssertEqual(reopened.unreadableProposals, [])
    XCTAssertEqual(
      try reopened.read {
        try $0.db.select("SELECT count(*) FROM held_proposals", []) { $0.int(at: 0) }
      }, [0])
  }

  /// 読めない候補も、出どころの今の集合の項目が無効になれば読める候補と同じく下がり、メモリからも外れて同じリンクを塞がない。
  func testAProposalThatCannotBeReadIsWithdrawnWhenItsOriginLeaves() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    let a = Self.item("a")
    try Self.fetch(XCTUnwrap(store), id, [a])
    try Self.judge(XCTUnwrap(store), id, proposing: [a])
    store = nil
    try database().run("UPDATE proposals SET due = 'x' WHERE link = ?", [.text(a.link)])
    let reopened = AutomationStore()
    XCTAssertEqual(reopened.unreadableProposals.map(\.link), [a.link], "前提: 読めない候補")

    try Self.fetch(reopened, id, [])

    XCTAssertEqual(reopened.unreadableProposals, [])
    XCTAssertFalse(reopened.heldLinks.contains(a.link))
  }

  /// 中身の JSON を壊した回の記録は、その 1 件だけが「不明な記録」として、時刻・契機・成否を持って残る。
  func testARunRecordThatCannotBeReadStaysAsAnUnknownRecord() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    try Self.fetch(XCTUnwrap(store), id, [Self.item("a")])
    try Self.fetch(
      XCTUnwrap(store), id, [], outcome: DesignSceneFixtures.failed("boom"),
      at: Self.at.addingTimeInterval(60))
    let records = try XCTUnwrap(store?.automation(id)?.state(key: "fetch").runs)
    store = nil
    try database().run(
      "UPDATE runs SET record = '{}' WHERE id = ?", [.integer(Int64(records[0].id))])

    let runs = try XCTUnwrap(AutomationStore().automation(id)?.state(key: "fetch").runs)

    XCTAssertEqual(runs.count, 2)
    XCTAssertNil(runs[0].run)
    XCTAssertEqual(
      runs[0].content,
      .unknown(
        AutomationUnknownRun(
          startedAt: Self.at.addingTimeInterval(60), endedAt: Self.at.addingTimeInterval(60),
          trigger: .schedule, failed: true)))
    XCTAssertEqual(runs[1], records[1], "ほかの記録はそのまま")
  }
}
