import XCTest

@testable import Orbe

/// 部品の同一性と定義の版——鍵はただの呼び名で、部品は Orbe が振る ID で見分ける。部品の定義は書き換えずに足し、自動化の
/// 書き換えは版を添えて送る。
///
/// 壊れると何が起きるか: 鍵を変えただけで部品が別物になり、読んだ行が全部もう一度流れて副作用が二重に走る・記録と候補と外した
/// 印を失う。下流へ渡す id や回の ID が鍵の変更で変わり、二重実行を防げない。名前や予定だけの書き換えで走っている回が止まる。
/// 指示文を直した後の記録が前の中身を指し、どの中身で動いた回か分からなくなる。人がボードで通知を切り替えた直後の AI の古い
/// 書き換えがそれを黙って戻す。id を書き忘れた書き換えで全部品が作り直される。
extension AutomationStoreTests {
  /// 取得の部品 `fetch` → 副作用のコマンド `send`。
  private func sendDefinition(fetchKey: String = "fetch", script: String = "fetch")
    -> AutomationDefinition
  {
    AutomationDefinition(
      name: "送る", notify: nil,
      parts: [
        DesignSceneFixtures.commandNode(
          fetchKey, "取る", .scheduled(.every(1800)), script: script, coverage: .currentSet),
        DesignSceneFixtures.commandNode(
          "send", "送る", .arrival, from: [fetchKey], script: "send", deliver: .sideEffect),
      ])
  }

  /// 受け手が今読めば取る行の下流へ渡す id。
  private func unread(_ store: AutomationStore, _ id: Int, _ key: String) throws -> [String] {
    try XCTUnwrap(store.read(store.nodeId(id, key), of: id, baseline: nil, now: Self.at)).taken.map(
      \.id)
  }

  /// 鍵を変えた書き換え（`from` の名指しも合わせて変える）の後も、部品は同じ ID のまま、読んだ位置・まだ受け取っていない行・
  /// 回の記録・外した印・候補を保ち、下流へ渡す id と回の ID も変わらない。鍵だけの変化は何をするかの変化に入らない（下流の
  /// 名指しが変わっただけの部品も）。
  func testRenamingANodeKeepsItsIdentity() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(), now: Self.at).id
    let (a, b) = (Self.item("a"), Self.item("b"))
    try Self.fetch(store, id, [a], outcome: Self.breached([a]))
    try Self.judge(store, id, proposing: [a])
    try Self.fetch(store, id, [a, b])
    let fetch = store.nodeId(id, "fetch")
    let before = try XCTUnwrap(store.automation(id))
    let unreadBefore = try unread(store, id, "judge")
    let anchor = before.state(fetch).anchor
    XCTAssertEqual(unreadBefore, ["\(fetch):b"], "前提: b がまだ受け取られていない")

    var renamed = before.definition
    renamed.parts[0].key = "gh"
    renamed.parts[1].from = [AutomationDefinition.Input(part: "gh")]
    let replaced = try store.replace(id, version: before.version, with: renamed, now: Self.at)

    let after = try XCTUnwrap(store.automation(id))
    XCTAssertEqual(store.nodeId(id, "gh"), fetch, "同じ部品のまま")
    XCTAssertEqual(replaced.reworked, [], "鍵だけの変化は何をするかの変化でない")
    XCTAssertEqual(try unread(store, id, "judge"), unreadBefore, "読んだ位置とまだ受け取っていない行")
    XCTAssertEqual(after.state(fetch).runs, before.state(fetch).runs)
    XCTAssertEqual(after.state(fetch).breach, before.state(fetch).breach)
    XCTAssertEqual(store.proposals.map(\.originNodeId), [fetch])
    XCTAssertEqual(
      AutomationRunner.runId(id, fetch, after.state(fetch).anchor),
      AutomationRunner.runId(id, fetch, anchor))
  }

  /// 鍵・名前・予定・件数の上限だけの変化は何をするかの変化に入らず、指示文の変化は新しい定義を足して指し直す。前の回の記録は
  /// 前の定義を、後の回の記録は新しい定義を指す。部品の定義の行は書いた後に変わらず、保存した値に部品の鍵が残るのは自動化の
  /// 部品の鍵だけ。
  func testOnlyWhatANodeDoesMakesANewDefinition() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(), now: Self.at).id
    try Self.fetch(store, id, [Self.item("a")])
    try Self.judge(store, id)
    let judge = store.nodeId(id, "judge")
    let first = try XCTUnwrap(store.automation(id)?.graph.node(judge)?.entity.defId)

    var plain = try XCTUnwrap(store.automation(id)?.definition)
    plain.parts[1].name = "別名"
    plain.parts[1].trigger = .manual
    plain.parts[1].maxItems = 5
    let renamed = try store.replace(id, version: 1, with: plain, now: Self.at)
    XCTAssertEqual(renamed.reworked, [])
    XCTAssertEqual(store.automation(id)?.graph.node(judge)?.entity.defId, first)

    var instructed = try XCTUnwrap(store.automation(id)?.definition)
    instructed.parts[1].action.method = .agent(
      AutomationNodeAgent(cli: "claude", model: "sonnet", tools: [], instruction: "別の基準"))
    let rewritten = try store.replace(id, version: 2, with: instructed, now: Self.at)
    try Self.judge(store, id, at: Self.at.addingTimeInterval(60))

    let second = try XCTUnwrap(store.automation(id)?.graph.node(judge)?.entity.defId)
    XCTAssertEqual(rewritten.reworked, [judge])
    XCTAssertNotEqual(second, first)
    XCTAssertEqual(
      try store.read {
        try $0.db.select(
          "SELECT def_id FROM runs WHERE part_id = ? ORDER BY id DESC",
          [.integer(Int64(judge.rawValue))]
        ) { AutomationDefID($0.int(at: 0)) }
      }, [second, first])
    let stored = try store.read { db in
      try db.db.select("SELECT action FROM action_defs ORDER BY id", []) { $0.text(at: 0) ?? "" }
    }
    XCTAssertEqual(stored.count, 3, "取得・判定・書き換えた判定")
    XCTAssertTrue(stored[1].contains("自分が何かを頼まれている"), "前の定義の行は変わらない")
    XCTAssertFalse(stored.contains { $0.contains(#""key""#) }, "定義に鍵は残らない")
  }

  /// 省略していた値に既定と同じ値を書き足すだけ（判定のモデル・上限）は、何をするかの変化に入らず、走っている回を止めない。
  /// 既定と違う値は変化。
  func testSpellingOutADefaultIsNotAChangeOfWork() throws {
    let store = AutomationStore()
    let id = try store.create(Self.definition(), now: Self.at).id
    let judge = store.nodeId(id, "judge")
    func rewritten(_ change: (inout AutomationActionDef) -> Void) throws -> [AutomationNodeID] {
      var definition = try XCTUnwrap(store.automation(id)?.definition)
      change(&definition.parts[1].action)
      let version = try XCTUnwrap(store.automation(id)?.version)
      return try store.replace(id, version: version, with: definition, now: Self.at).reworked
    }
    func model(_ model: String?) -> (inout AutomationActionDef) -> Void {
      { action in
        guard case .agent(var agent) = action.method else { return }
        agent.model = model
        action.method = .agent(agent)
      }
    }

    XCTAssertEqual(try rewritten(model(nil)), [], "省略は既定の sonnet と同じ")
    XCTAssertEqual(
      try rewritten { $0.timeoutMinutes = AutomationActionDef.agentTimeoutMinutes }, [],
      "agent の既定の上限を明示")
    XCTAssertEqual(try rewritten(model("opus")), [judge])
    XCTAssertEqual(try rewritten { $0.timeoutMinutes = 9 }, [judge])
  }

  /// 先頭に新しい部品を挿し、残す部品の鍵を変えてその旧鍵を新しい部品に使う書き換えも通り、残す部品は ID を保ち、部品は定義の
  /// 順に並ぶ（DB の位置も）。
  func testARewriteCanInsertANodeAndHandItAnOldKey() throws {
    let store = AutomationStore()
    let id = try store.create(sendDefinition(), now: Self.at).id
    let (fetch, send) = (store.nodeId(id, "fetch"), store.nodeId(id, "send"))
    var definition = try XCTUnwrap(store.automation(id)?.definition)
    definition.parts[0].key = "gh"
    definition.parts[1].from = [AutomationDefinition.Input(part: "gh")]
    definition.parts.insert(
      DesignSceneFixtures.commandNode(
        "fetch", "掃除", .scheduled(.every(3600)), script: "clean", deliver: .sideEffect), at: 0)

    _ = try store.replace(id, version: 1, with: definition, now: Self.at)

    let nodes = try XCTUnwrap(store.automation(id)?.graph.nodes)
    XCTAssertEqual(nodes.map(\.key), ["fetch", "gh", "send"])
    XCTAssertEqual(Array(nodes.map(\.id).dropFirst()), [fetch, send], "残す部品は同じ ID")
    XCTAssertGreaterThan(nodes[0].id, send, "新しい部品")
    XCTAssertEqual(
      try store.read {
        try $0.db.select(
          "SELECT key FROM parts WHERE automation_id = ? AND removed_at IS NULL ORDER BY position",
          [.integer(Int64(id))]
        ) { $0.text(at: 0) ?? "" }
      }, ["fetch", "gh", "send"])
  }

  /// 書き換えは版を添えて送り、通れば版が 1 増える。id の無い部品は新しい部品になる。止める・再開は版を変えない。
  func testARewriteCarriesTheVersionAndBumpsIt() throws {
    let store = AutomationStore()
    let id = try store.create(sendDefinition(), now: Self.at).id
    XCTAssertEqual(store.automation(id)?.version, 1)
    var definition = try XCTUnwrap(store.automation(id)?.definition)
    XCTAssertEqual(
      definition.parts.map(\.id), [store.nodeId(id, "fetch"), store.nodeId(id, "send")])
    definition.parts.append(
      DesignSceneFixtures.commandNode(
        "log", "記録", .arrival, from: ["fetch"], script: "log", deliver: .sideEffect))

    let replaced = try store.replace(id, version: 1, with: definition, now: Self.at)
    _ = try store.setPaused(id, true, now: Self.at)
    _ = try store.setPaused(id, false, now: Self.at)

    XCTAssertEqual(replaced.automation.version, 2)
    XCTAssertEqual(store.automation(id)?.version, 2, "止める・再開は版を変えない")
    XCTAssertGreaterThan(store.nodeId(id, "log"), store.nodeId(id, "send"), "新しい部品に ID が振られる")
    XCTAssertEqual(
      try store.replace(
        id, version: 2, with: XCTUnwrap(store.automation(id)?.definition), now: Self.at
      )
      .automation.version, 2, "何も変わらない書き換えは版を進めない")
  }

  /// 次の書き換えは断られ、定義は変わらない: 版が無い・古い（間に通知を切り替えた）、知らない部品の id・ほかの自動化の部品の
  /// id、新しく作る定義の id、id を落として消える部品と同じ鍵で書いた部品。
  func testRewritesThatWouldLoseOrMixUpNodesAreRefused() throws {
    let store = AutomationStore()
    let id = try store.create(sendDefinition(), now: Self.at).id
    let other = try store.create(sendDefinition(), now: Self.at).id
    let current = try XCTUnwrap(store.automation(id)?.definition)
    var notified = current
    notified.notify = .menuBar
    _ = try store.replace(id, version: 1, with: notified, now: Self.at)
    let fetch = store.nodeId(id, "fetch")
    func refused(_ version: Int?, _ change: (inout AutomationDefinition) -> Void)
      -> AutomationError?
    {
      var definition = current
      change(&definition)
      do throws(AutomationError) {
        _ = try store.replace(id, version: version, with: definition, now: Self.at)
        return nil
      } catch {
        return error
      }
    }

    XCTAssertEqual(
      refused(nil) { _ in },
      .invalid("version: pass the version you read with list_automations to rewrite"))
    XCTAssertEqual(refused(1) { _ in }, .versionMismatch(sent: 1, current: 2))
    XCTAssertEqual(
      refused(2) { $0.parts[0].id = AutomationNodeID(999) },
      .invalid("parts[0].id: 999 is not a part of automation \(id)"))
    XCTAssertEqual(
      refused(2) { $0.parts[0].id = store.nodeId(other, "fetch") },
      .invalid("parts[0].id: \(store.nodeId(other, "fetch")) is not a part of automation \(id)"))
    XCTAssertEqual(
      refused(2) { $0.parts[0].id = nil },
      .invalid(
        "parts[0].id: the key \"fetch\" belongs to part \(fetch); send its id to keep the part, or "
          + "use another key for a new part"))
    XCTAssertThrowsError(try store.create(current, now: Self.at)) {
      XCTAssertEqual(
        $0 as? AutomationError, .invalid("parts[0].id: a new automation has no part ids yet"))
    }
    XCTAssertEqual(store.automation(id)?.definition, notified.withIds(of: store, id))
  }
}

extension AutomationDefinition {
  /// 部品に、自動化の今の同じ鍵の部品の id を添えたもの（テスト）。
  fileprivate func withIds(of store: AutomationStore, _ id: Int) -> AutomationDefinition {
    var definition = self
    for index in definition.parts.indices {
      definition.parts[index].id =
        store.automation(id)?.graph.node(
          key: definition.parts[index].key)?.id
    }
    return definition
  }
}
