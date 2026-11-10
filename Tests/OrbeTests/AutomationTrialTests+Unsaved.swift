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
    try unsaved(.create(definition(definitionNodes)))
  }

  /// `start` 番目から後に呼ばれた手段を、呼ばれた順に `output`（スクリプトと読んだ行の id から出力を決める）で終え、新しい呼び出しが
  /// 無く `done` が立てば返す。`failing` のスクリプトは失敗で終える。スクリプトごとに、呼ばれた順の読んだ行の id を返す。回の順が
  /// 本番と食い違っても最後まで進める。
  func answer(
    from start: Int, until done: () -> Bool = { true }, failing: Set<String> = [],
    _ output: (_ script: String, _ ids: [String]) -> String
  ) -> [String: [[String]]] {
    var read: [String: [[String]]] = [:]
    var next = start
    while true {
      settle(until: { done() || jobs.calls.count > next })
      guard jobs.calls.count > next else { return read }
      let script = script(at: next) ?? ""
      read[script, default: []].append(ids(at: next))
      finish(at: next, output(script, ids(at: next)), exit: failing.contains(script) ? 1 : 0)
      next += 1
    }
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
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
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
    XCTAssertEqual(calls("p2").count, 2, "前提: 書いた後の本番でも p2 が走る")
    XCTAssertEqual(calls("digest").count, 2, "前提: 書いた後の本番でも digest が走る")
    XCTAssertEqual(tried.p2, [downstream("gh", "b", of: id)], "前提: 読んだ位置から続く")
    XCTAssertEqual(ids("p2"), tried.p2)
    XCTAssertEqual(
      tried.digest, [downstream("gh", "a", of: id), downstream("gh", "b", of: id)],
      "前提: 足したノードは今の集合の全件を読む")
    XCTAssertEqual(ids("digest"), tried.digest)
  }

  /// 直す試走は、予定だけを「届いたら」に変えたノードも本番で書いた時点と同じに起こす: 読んでいない b を書いた時点の回で読み、
  /// 流しで足された c を次の回で読む（予定は何をするかに入らないので、そのノードは何をするかが変わったノードではない）。
  func testARewriteWakesANodeTurnedToArrivalAsWritingItInProductionDoes() throws {
    let id = try define([fetch("gh"), definitionNode("p", from: ["gh"], deliver: .report)])
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("p", "a")
    try runner.flow(id, to: .node(store.nodeId(id, "gh")))
    finish("gh", fetched(["a", "b"]))
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.nodes[1].trigger = .arrival
    let output = { (script: String, _: [String]) in
      script == "gh" ? self.fetched(["a", "b", "c"]) : "読んだ"
    }

    let start = jobs.calls.count
    let trial = try trials.start(
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
    let tried = answer(from: start, until: { !trial.running }, output)
    XCTAssertNil(trial.failure)

    let writing = jobs.calls.count
    _ = try runner.set(id, version: current.version, rewrite)
    var written = answer(from: writing, output)
    let flowing = jobs.calls.count
    try runner.flow(id, to: .ends)
    written.merge(answer(from: flowing, output)) { $0 + $1 }
    XCTAssertEqual(
      written["p"], [[downstream("gh", "b", of: id)], [downstream("gh", "c", of: id)]],
      "前提: 本番では書いた時点で b を読み、流しで c を読む")
    XCTAssertEqual(tried["p"], written["p"])
  }

  /// 直す試走は、上流の出力の性質を変えたとき、変えていない毎回すべてを取るノードも本番で書いた時点と同じに起こす: そのノードは
  /// 無効になった上流を空の集合として写し、流しで写し直した a も新しい行として副作用に渡る（本番では a の副作用がもう一度走る）。
  func testARewriteOfTheUpstreamsCoverageHoldsWhatTheSideEffectGetsAgainAsInProduction() throws {
    var copy = DesignSceneFixtures.commandNode(
      "copy", "copy", .arrival, script: "copy", coverage: .currentSet)
    copy.from = [AutomationDefinition.Input(nodeKey: "gh", take: .all)]
    let id = try define([
      fetch("gh"), copy, definitionNode("post", .arrival, from: ["copy"], deliver: .sideEffect),
    ])
    let output = { (script: String, ids: [String]) -> String in
      switch script {
      case "gh": self.fetched(["a", "b"])
      case "copy":
        ids.map { #"{"id":"\#($0.split(separator: ":").last ?? "")","body":"写し"}"# }
          .joined(separator: "\n")
      default: ""
      }
    }
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("copy", output("copy", ids("copy")))
    finish("post", "")
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.nodes[0].action.coverage = .newArrivals

    let start = jobs.calls.count
    let trial = try trials.start(
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
    _ = answer(from: start, until: { !trial.running }, output)
    XCTAssertNil(trial.failure)
    let held = trial.passes(key: "post").reversed().compactMap(\.heldIds)

    let writing = jobs.calls.count
    _ = try runner.set(id, version: current.version, rewrite)
    var written = answer(from: writing, output)
    let flowing = jobs.calls.count
    try runner.flow(id, to: .ends)
    written.merge(answer(from: flowing, output)) { $0 + $1 }
    XCTAssertEqual(written["copy"]?.first, [], "前提: 本番では書いた時点で copy が空の集合を写す")
    XCTAssertEqual(
      written["post"], [[downstream("copy", "a", of: id), downstream("copy", "b", of: id)]],
      "前提: 本番では a の副作用がもう一度走る")
    XCTAssertEqual(held, written["post"])
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
      try unsaved(.replace(id, version: current.version, rewrite)),
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
    XCTAssertEqual(calls("judge").count, 3, "前提: 書いた後の本番でも判定が走る")
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
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
    var other = current.definition
    other.name = "ほかで直した"
    _ = try runner.set(id, version: current.version, other)
    ended(trial)

    XCTAssertEqual(
      trial.failure,
      AutomationError.versionMismatch(sent: current.version, current: current.version + 1).message)
    XCTAssertEqual(calls("gh"), [])
  }

  /// 範囲と与える行は書く前の定義の鍵で解く: 足すノードも指せ、与えた行は足すノードの出力として流れる。知らない鍵は、直す試走でも
  /// 新しい定義でも定義の中の参照の誤りとして、始めるときに断る。与える行が 1 つも無いのも断る。
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
    let target = try unsaved(.replace(id, version: current.version, rewrite))
    XCTAssertThrowsError(try trials.start(target, .init(from: ["nope"]))) {
      XCTAssertEqual($0 as? AutomationError, .invalid(#"from[0]: unknown node "nope""#))
    }
    XCTAssertThrowsError(try trials.start(target, .init(from: ["digest"], rows: []))) {
      XCTAssertEqual($0 as? AutomationError, .invalid("rows must have at least one row"))
    }
    let ranged = try trials.start(target, .init(from: ["gh"], to: ["digest"]))
    XCTAssertEqual(ranged.keys.path, ["gh", "digest"])
    XCTAssertEqual(ranged.keys.to, ["digest"])
    ranged.stop()
  }
}
