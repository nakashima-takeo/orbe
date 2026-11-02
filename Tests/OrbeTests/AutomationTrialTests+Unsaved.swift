import XCTest

@testable import Orbe

/// 書く前の定義の試走——写しのストアに本番と同じ作成・書き換えを掛けてから流す。
///
/// 壊れると何が起きるか: 書く前の定義を試したつもりが本番に自動化が増える・定義や版が変わる。直す試走が本番で書き換えた直後の
/// 次の回と違う読み始めで流れ、試走で確かめた判定の基準が本番では別の行を読む。写す間に本番が書き換わっても、古い版の上で黙って
/// 流れる。足すノードを範囲や与える行で指せない。
extension AutomationTrialTests {
  private func create(_ definitionNodes: [AutomationDefinition.Node]) throws
    -> AutomationTrial.Target
  {
    .unsaved(try store.check(.create(definition(definitionNodes))))
  }

  /// 新しい定義の試走は、作れば受かる定義を写しの上で作って流し、結果のノードは定義の鍵で並ぶ。本番には何も増えず、知らせも
  /// 出ない。外の形は試走の ID を持ち、自動化の ID を持たない。
  func testANewDefinitionRunsOnTheCopyAndLeavesProductionWithoutIt() throws {
    let trial = try trials.start(
      try create([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)]), .init())
    XCTAssertEqual(trial.keys.path, ["gh", "d"], "写し終える前から定義の鍵で並ぶ")
    waitCalls("gh", 1)
    finish("gh", fetched(["a"]))
    waitCalls("d", 1)
    finish("d", "a が来た")
    ended(trial)

    XCTAssertNil(trial.failure)
    XCTAssertEqual(["gh", "d"].map { trial.state(key: $0) }, [.done, .done])
    XCTAssertEqual(trial.passes(key: "d").first?.run?.result, .report(text: "a が来た"))
    XCTAssertTrue(store.automations.isEmpty)
    XCTAssertTrue(recorded.isEmpty)
    let json = trial.json { _ in nil }
    XCTAssertEqual(json["trialId"] as? Int, trial.id)
    XCTAssertNil(json["automationId"])
  }

  /// 直す試走は、本番で書き換えた直後の次の回と同じに流れる: ID を保ったノードは本番の読んだ位置から続き、何をするかを変えた
  /// ノードも同じ入力なら読んだ位置を保ち、足したノードは今の集合の全件を読む。本番の定義・版・状態は変わらない。
  func testARewriteRunsLikeTheNextFlowAfterWritingItInProduction() throws {
    let id = try define([
      fetch("gh"), definitionNode("p", from: ["gh"]),
      definitionNode("d", from: ["p"], deliver: .report),
    ])
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("p", #"{"id":"\#(downstream("gh", "a", of: id))"}"#)
    finish("d", "a")
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.nodes[1].action.method = .command(AutomationNodeCommand(script: "p2"))
    rewrite.nodes.append(definitionNode("digest", from: ["gh"], deliver: .report))
    let automations = store.automations
    let notices = recorded

    let trial = try trials.start(
      .unsaved(try store.check(.replace(id, version: current.version, rewrite))), .init())
    waitCalls("gh", 2)
    finish("gh", fetched(["a", "b"]))
    waitCalls("p2", 1)
    waitCalls("digest", 1)
    let tried = (p2: ids("p2"), digest: ids("digest"))
    finish("p2", "")
    finish("digest", "a と b")
    ended(trial)
    XCTAssertNil(trial.failure)
    XCTAssertEqual(store.automations, automations)
    XCTAssertEqual(recorded, notices)
    XCTAssertEqual(trial.json { _ in nil }["automationId"] as? Int, id)

    _ = try runner.set(id, version: current.version, rewrite)
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a", "b"]))
    XCTAssertEqual(tried.p2, [downstream("gh", "b", of: id)], "前提: 読んだ位置から続く")
    XCTAssertEqual(ids("p2"), tried.p2)
    XCTAssertEqual(
      tried.digest, [downstream("gh", "a", of: id), downstream("gh", "b", of: id)],
      "前提: 足したノードは今の集合の全件を読む")
    XCTAssertEqual(ids("digest"), tried.digest)
  }

  /// 直す試走は、本番で書いたときと同じく、入力を変えた判定の判断待ちの候補に下げる条件を当て直す: 外した入力だけが支えていた
  /// 候補は写しの上で下がり、試走の判定は同じリンクを新しい候補にする（本番で書いた後の次の回と同じ結果）。本番の候補は残る。
  func testARewriteReviewsTheJudgesWaitingProposalsAsWritingItInProductionDoes() throws {
    func row(_ id: String) -> String {
      #"{"id":"\#(id)","link":"https://example.com/a","body":"\#(id)","time":"2026-10-10T09:00:00Z"}"#
    }
    let id = try define([
      fetch("gh"), fetch("gl"),
      definitionNode("judge", from: ["gh", "gl"], deliver: .taskCandidates),
      definitionNode("d", from: ["gl"], deliver: .report),
    ])
    let judge = store.nodeId(id, "judge")
    let propose = #"{"propose":"\#(downstream("gh", "a", of: id))","title":"A"}"#
    try runner.flow(id, to: .node(judge))
    finish("gh", row("a"))
    finish("gl", row("b"))
    finish("judge", propose)
    try runner.flow(id, to: .node(store.nodeId(id, "gh")))
    finish("gh", "")
    XCTAssertEqual(store.openProposals(of: judge).count, 1, "前提: 元の項目は消えたが、gl の行が同じリンクで支える")
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.nodes[2].from = [AutomationDefinition.Input(nodeKey: "gh")]
    let proposals = store.proposals

    let trial = try trials.start(
      .unsaved(try store.check(.replace(id, version: current.version, rewrite))),
      .init(to: ["judge"]))
    waitCalls("gh", 3)
    finish("gh", row("a"))
    waitCalls("judge", 2)
    finish("judge", propose)
    ended(trial)
    XCTAssertNil(trial.failure)
    XCTAssertEqual(store.proposals, proposals)

    _ = try runner.set(id, version: current.version, rewrite)
    try runner.flow(id, to: .node(judge))
    finish("gh", row("a"))
    finish("judge", propose)
    let written = try XCTUnwrap(store.automation(id)?.state(key: "judge").runs.first?.run?.result)
    XCTAssertEqual(written, .judge(proposed: 1, resolved: 0, dismissed: []), "前提: 書いた後の次の回は候補にする")
    XCTAssertEqual(trial.passes(key: "judge").first?.run?.result, written)
  }

  /// 直す試走を始めた後、写し終える前に本番が書き換わると、試走は `set_automation` と同じ版の食い違いの文で終わり、何も流さない。
  func testARewriteEndsWhenProductionMovesOnWhileCopying() throws {
    let id = try define([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)])
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.name = "直した"
    let trial = try trials.start(
      .unsaved(try store.check(.replace(id, version: current.version, rewrite))), .init())
    var other = current.definition
    other.name = "ほかで直した"
    _ = try runner.set(id, version: current.version, other)
    ended(trial)

    XCTAssertEqual(
      trial.failure,
      AutomationError.versionMismatch(sent: current.version, current: current.version + 1).message)
    XCTAssertEqual(calls("gh"), [])
  }

  /// 範囲と与える行は書く前の定義の鍵で解く: 足すノードも指せ、与えた行は足すノードの出力として流れる。知らない鍵は、直す試走
  /// ならその自動化のノードが無い、新しい定義なら定義の中の参照の誤りとして、始めるときに断る。
  func testRangeAndRowsResolveOnTheUnsavedDefinition() throws {
    let trial = try trials.start(
      try create([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)]),
      .init(from: ["d"], rows: [#"{"id":"x"}"#]))
    waitCalls("d", 1)
    XCTAssertEqual(ids("d").count, 1)
    XCTAssertEqual(ids("d").first?.hasSuffix(":x"), true)
    XCTAssertEqual(calls("gh"), [])
    finish("d", "x")
    ended(trial)
    XCTAssertEqual(trial.keys.path, ["d"])

    XCTAssertThrowsError(
      try trials.start(
        try create([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)]),
        .init(to: ["nope"]))
    ) {
      XCTAssertEqual($0 as? AutomationError, .invalid(#"to[0]: unknown node "nope""#))
    }
    let id = try define([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)])
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.nodes.append(definitionNode("digest", from: ["gh"], deliver: .report))
    let target = AutomationTrial.Target.unsaved(
      try store.check(.replace(id, version: current.version, rewrite)))
    XCTAssertThrowsError(try trials.start(target, .init(from: ["nope"]))) {
      XCTAssertEqual($0 as? AutomationError, .nodeNotFound(id, "nope"))
    }
    let ranged = try trials.start(target, .init(from: ["gh"], to: ["digest"]))
    XCTAssertEqual(ranged.keys.path, ["gh", "digest"])
    XCTAssertEqual(ranged.keys.to, ["digest"])
    ranged.stop()
  }
}
