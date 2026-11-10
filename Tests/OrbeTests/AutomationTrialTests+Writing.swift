import XCTest

@testable import Orbe

/// 直す試走の書いた時点の分——本番で書いた時点に起きる回と、その確定から続く起こしの回を、写しの上でも本番と同じに起こす。試走の
/// 結果は、その分を流しの分と見分けて返す。
///
/// 壊れると何が起きるか: 書いた瞬間に動く副作用や予定の回が試走の結果に出ず、AI と人は「書いても次の回まで何も動かない」と読む。
/// 書いた時点の回の下流の副作用に渡る行が、流しの分と混ざる・消える・2 度出る。書いた時点の回を待たずに流し、確定の順が本番と
/// 入れ替わる。
extension AutomationTrialTests {
  /// 処理 p が読んだ行を `<書かれた id>2` の行にして出す（取得は `fetchedIds` の行を出し、ほかは何も出さない）。
  private func echo(_ fetchedIds: [String]) -> (String, [String]) -> String {
    { script, ids in
      switch script {
      case "gh": self.fetched(fetchedIds)
      case "p":
        ids.map { #"{"id":"\#($0.split(separator: ":").last ?? "")2"}"# }.joined(separator: "\n")
      default: ""
      }
    }
  }

  /// 直す試走は、書いた時点に起きる回をすべて待ってから流す: 何をするかが変わった「届いたら」のノード（p2）と足した「届いたら」の
  /// ノード（q）が書いた時点に起き、片方が終わっても流さず、両方が終わってから流しの取得が走る。どちらも本番で書いて流したときと
  /// 同じ行を読む。
  func testARewriteFlowsOnlyAfterEveryRunAtWritingEnds() throws {
    let id = try define([
      fetch("gh"), definitionNode("p", .arrival, from: ["gh"], deliver: .report),
    ])
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("p", "", exit: 1)
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.nodes[1].action.method = .command(AutomationNodeCommand(script: "p2"))
    rewrite.nodes.append(definitionNode("q", .arrival, from: ["gh"], deliver: .report))

    let trial = try trials.start(
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
    waitCalls("p2", 1)
    waitCalls("q", 1)
    let triedAtWriting = [ids("p2"), ids("q")]
    finish("p2", "a")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(calls("gh").count, 1, "書いた時点の回がすべて終わるまで流さない")
    finish("q", "a")
    waitCalls("gh", 2)
    finish("gh", fetched(["a", "b"]))
    waitCalls("p2", 2)
    waitCalls("q", 2)
    let triedInFlow = [ids("p2"), ids("q")]
    finish("p2", "b")
    finish("q", "b")
    ended(trial)
    XCTAssertNil(trial.failure)

    _ = try runner.set(id, version: current.version, rewrite)
    XCTAssertEqual(calls("p2").count, 3, "前提: 本番では書いた時点で p2 が起きる")
    XCTAssertEqual(calls("q").count, 3, "前提: 本番では書いた時点で q が起きる")
    let written = [ids("p2"), ids("q")]
    finish("p2", "a")
    finish("q", "a")
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a", "b"]))
    XCTAssertEqual(calls("p2").count, 4, "前提: 書いた後の流しでも p2 が走る")
    XCTAssertEqual(calls("q").count, 4, "前提: 書いた後の流しでも q が走る")
    XCTAssertEqual(triedAtWriting, written)
    XCTAssertEqual(triedInFlow, [ids("p2"), ids("q")])
  }

  /// 書いた時点に起きた回の確定から続く止めるノードの起こしも写す: 足した処理 p が書いた時点に今の集合を読んで出した行と、流しで
  /// 出した行は、足した副作用 send に本番と同じ分かれ方で渡るはずだった行として出る。回にも、渡るはずだった行にも、
  /// 書いた時点の分には `atWrite` が付き、流しの分には付かない。
  func testARewriteHoldsWhatASideEffectGetsAtWritingApartFromTheFlow() throws {
    let id = try define([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)])
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("d", "a")
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.nodes += [
      definitionNode("p", .arrival, from: ["gh"]),
      definitionNode("send", .arrival, from: ["p"], deliver: .sideEffect),
    ]
    let output = echo(["a", "b"])

    let start = jobs.calls.count
    let trial = try trials.start(
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
    _ = answer(from: start, until: { !trial.running }, output)
    XCTAssertNil(trial.failure)
    XCTAssertEqual(calls("send"), [], "副作用は写しの上でも走らない")
    let sends = trial.passes(key: "send").reversed()
    let nodes = trial.json { _ in nil }["nodes"] as? [[String: Any]]
    let sendRuns = nodes?.first { $0["key"] as? String == "send" }?["runs"] as? [[String: Any]]

    let writing = jobs.calls.count
    _ = try runner.set(id, version: current.version, rewrite)
    var written = answer(from: writing, output)
    let flowing = jobs.calls.count
    try runner.flow(id, to: .ends)
    written.merge(answer(from: flowing, output)) { $0 + $1 }
    XCTAssertEqual(
      written["send"], [[downstream("p", "a2", of: id)], [downstream("p", "b2", of: id)]],
      "前提: 本番では書いた時点に a2、流しで b2 が副作用に渡る")
    XCTAssertEqual(sends.compactMap(\.heldIds), written["send"])
    XCTAssertEqual(sends.map(\.atWrite), [true, false])
    XCTAssertEqual(trial.passes(key: "p").reversed().map(\.atWrite), [true, false])
    XCTAssertEqual(trial.passes(key: "d").map(\.atWrite), [false])
    XCTAssertEqual(
      sendRuns?.map { $0["atWrite"] as? Bool }, [nil, true],
      "trial の JSON の runs も新しい順で、書いた時点の分だけが atWrite を持つ")
  }

  /// 書いた時点に読んだ止めるノードは、流しで上流が変わらなければ読み直さない: 足した `take: all` の「届いたら」の副作用は、本番と
  /// 同じく書いた時点の 1 回だけ渡るはずだった行を返す。
  func testAHeldNodeReadAtWritingIsNotReadAgainWhenTheFlowChangesNothing() throws {
    let id = try define([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)])
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("d", "a")
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    var send = definitionNode("send", .arrival, deliver: .sideEffect)
    send.from = [AutomationDefinition.Input(nodeKey: "gh", take: .all)]
    rewrite.nodes.append(send)
    let output = echo(["a"])

    let start = jobs.calls.count
    let trial = try trials.start(
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
    _ = answer(from: start, until: { !trial.running }, output)
    XCTAssertNil(trial.failure)

    let writing = jobs.calls.count
    _ = try runner.set(id, version: current.version, rewrite)
    var written = answer(from: writing, output)
    let flowing = jobs.calls.count
    try runner.flow(id, to: .ends)
    written.merge(answer(from: flowing, output)) { $0 + $1 }
    XCTAssertEqual(
      written["send"], [[downstream("gh", "a", of: id)]], "前提: 本番の副作用は書いた時点の 1 回だけ")
    XCTAssertEqual(trial.passes(key: "send").compactMap(\.heldIds), written["send"])
    XCTAssertEqual(trial.passes(key: "send").map(\.atWrite), [true])
  }

  /// 本番で書いた時点に過ぎていた予定の回も写しの上で起こす: 手動から短い間隔に変えたノードは、書いた時点に予定の回として読んで
  /// いない行を読み、流しで足された行を次の回で読む。どちらも本番で書いて流したときと同じ行。
  func testARewriteRunsTheScheduleThatWritingMakesOverdueAsInProduction() throws {
    let id = try define([fetch("gh"), definitionNode("p", from: ["gh"], deliver: .report)])
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("p", "a")
    try runner.flow(id, to: .node(store.nodeId(id, "gh")))
    finish("gh", fetched(["a", "b"]))
    now += 3600
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.nodes[1].trigger = .scheduled(.every(60))
    let output = { (script: String, _: [String]) in
      script == "gh" ? self.fetched(["a", "b", "c"]) : "読んだ"
    }

    let start = jobs.calls.count
    let trial = try trials.start(
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
    let tried = answer(from: start, until: { !trial.running }, output)
    XCTAssertNil(trial.failure)
    let runs = trial.passes(key: "p").reversed().compactMap { $0.run }

    let writing = jobs.calls.count
    _ = try runner.set(id, version: current.version, rewrite)
    var written = answer(from: writing, output)
    let flowing = jobs.calls.count
    try runner.flow(id, to: .ends)
    written.merge(answer(from: flowing, output)) { $0 + $1 }
    XCTAssertEqual(
      written["p"], [[downstream("gh", "b", of: id)], [downstream("gh", "c", of: id)]],
      "前提: 本番では書いた時点に予定の回が b を読み、流しで c を読む")
    XCTAssertEqual(tried["p"], written["p"])
    XCTAssertEqual(runs.map(\.trigger), [.schedule, .now])
    XCTAssertEqual(trial.passes(key: "p").reversed().map(\.atWrite), [true, false])
  }

  /// 書いた時点に過ぎていた予定の回は、止めるノードでも書いた時点の分として起きる: 手動から短い間隔に変えた副作用は、本番で書いて
  /// 流したときに副作用が受け取る行と同じ分かれ方で、書いた時点の分と流しの分に渡るはずだった行を持つ。
  func testARewriteHoldsWhatAnOverdueSideEffectGetsAtWritingAsInProduction() throws {
    let id = try define([fetch("gh"), definitionNode("send", from: ["gh"], deliver: .sideEffect)])
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("send", "")
    try runner.flow(id, to: .node(store.nodeId(id, "gh")))
    finish("gh", fetched(["a", "b"]))
    now += 3600
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.nodes[1].trigger = .scheduled(.every(60))
    let output = { (script: String, _: [String]) in
      script == "gh" ? self.fetched(["a", "b", "c"]) : ""
    }

    let start = jobs.calls.count
    let trial = try trials.start(
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
    _ = answer(from: start, until: { !trial.running }, output)
    XCTAssertNil(trial.failure)
    XCTAssertEqual(calls("send").filter { $0 >= start }, [], "副作用は写しの上でも走らない")
    let sends = trial.passes(key: "send").reversed()

    let writing = jobs.calls.count
    _ = try runner.set(id, version: current.version, rewrite)
    var written = answer(from: writing, output)
    let flowing = jobs.calls.count
    try runner.flow(id, to: .ends)
    written.merge(answer(from: flowing, output)) { $0 + $1 }
    XCTAssertEqual(
      written["send"], [[downstream("gh", "b", of: id)], [downstream("gh", "c", of: id)]],
      "前提: 本番では書いた時点に副作用が b を受け取り、流しで c を受け取る")
    XCTAssertEqual(sends.compactMap(\.heldIds), written["send"])
    XCTAssertEqual(sends.map(\.atWrite), [true, false])
  }

  /// 入力の無い止めるノードも、起きるたびに渡るはずだった行（中身は空）を返す: 手動から短い間隔に変えた入力の無い副作用は、本番で
  /// 書いて流したときに副作用のコマンドが起きる回（書いた時点と流し）と同じ数だけ、空の渡るはずだった行を持つ。
  func testARewriteHoldsEachTimeASideEffectWithoutInputsWouldRunAsInProduction() throws {
    let id = try define([definitionNode("send", deliver: .sideEffect)])
    try runner.flow(id, to: .ends)
    finish("send", "")
    now += 3600
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.nodes[0].trigger = .scheduled(.every(60))
    let output = { (_: String, _: [String]) in "" }

    let start = jobs.calls.count
    let trial = try trials.start(
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
    _ = answer(from: start, until: { !trial.running }, output)
    XCTAssertNil(trial.failure)
    let sends = trial.passes(key: "send").reversed()

    let writing = jobs.calls.count
    _ = try runner.set(id, version: current.version, rewrite)
    XCTAssertEqual(calls("send").filter { $0 >= writing }.count, 1, "前提: 本番では書いた時点に副作用が起きる")
    _ = answer(from: writing, output)
    let flowing = jobs.calls.count
    try runner.flow(id, to: .ends)
    _ = answer(from: flowing, output)
    XCTAssertEqual(calls("send").filter { $0 >= flowing }.count, 1, "前提: 流しでも副作用が起きる")
    XCTAssertEqual(sends.compactMap(\.heldIds), [[], []])
    XCTAssertEqual(sends.map(\.atWrite), [true, false])
  }

  /// 写した時点に本番で予定の回が走っているノードは、写しの上では結果を残さずに終わった回として引き継ぐ: 走っている回が間隔を過ぎて
  /// いなければ、本番と同じく書いた時点に予定の回を起こさず、その回が読んでいる行は流しで読む。
  func testARewriteDoesNotRunAgainAtWritingAScheduleRunningInProduction() throws {
    let id = try define([
      fetch("gh"), definitionNode("p", .scheduled(.every(60)), from: ["gh"], deliver: .report),
    ])
    try runner.flow(id, to: .node(store.nodeId(id, "gh")))
    finish("gh", fetched(["a"]))
    now += 120
    runner.scheduler.recount()
    XCTAssertEqual(ids("p"), [downstream("gh", "a", of: id)], "前提: p の予定の回が本番で走っている")
    now += 10
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.name = "直した"
    let output = { (script: String, _: [String]) in
      script == "gh" ? self.fetched(["a"]) : "読んだ"
    }

    let start = jobs.calls.count
    let trial = try trials.start(
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
    let tried = answer(from: start, until: { !trial.running }, output)
    XCTAssertNil(trial.failure)

    let writing = jobs.calls.count
    _ = try runner.set(id, version: current.version, rewrite)
    XCTAssertEqual(jobs.calls.count, writing, "前提: 本番では書いた時点に何も起きない")
    XCTAssertEqual(tried["p"], [[downstream("gh", "a", of: id)]])
    XCTAssertEqual(trial.passes(key: "p").compactMap { $0.run?.trigger }, [.now])
    XCTAssertEqual(trial.passes(key: "p").map(\.atWrite), [false])
  }

  /// 写しの走らせ役は本番の前の契機の印を引き継ぐ: 失敗した回が残した行（基準線以下）では、本番と同じく書いた時点に「届いたら」の
  /// ノードを起こさず、流しの祖先の予定でのやり直しで読む。
  func testARewriteKeepsProductionsMarksSoARowAFailedRunLeftDoesNotWakeAtWriting() throws {
    let id = try define([
      fetch("gh"), definitionNode("p", .arrival, from: ["gh"], deliver: .report),
    ])
    try runner.flow(id, to: .ends)
    finish("gh", fetched(["a"]))
    finish("p", "", exit: 1)
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.name = "直した"
    let output = echo(["a"])

    let start = jobs.calls.count
    let trial = try trials.start(
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
    let tried = answer(from: start, until: { !trial.running }, output)
    XCTAssertNil(trial.failure)

    let writing = jobs.calls.count
    _ = try runner.set(id, version: current.version, rewrite)
    XCTAssertEqual(jobs.calls.count, writing, "前提: 本番では書いた時点に何も起きない")
    try runner.flow(id, to: .ends)
    let written = answer(from: writing, output)
    XCTAssertEqual(written["p"], [[downstream("gh", "a", of: id)]], "前提: 流しのやり直しで a を読む")
    XCTAssertEqual(tried["p"], written["p"])
    XCTAssertEqual(trial.passes(key: "p").map(\.atWrite), [false])
  }

  /// 写しの走らせ役は、本番の走らせ役が番人に今返すはずの数え始め（予定の次の時刻を数える起点）も引き継ぐ。予定の回が取る行 0 件で
  /// 終わって回の記録を残さなかった場合も、写しの走らせ役は本番と同じく、書いた時点に予定の回を起こさない。その後に届いた行は流しで読む。
  func testARewriteKeepsProductionsAnchorSoAScheduleThatTookNothingIsNotOverdueAtWriting() throws {
    let id = try define([
      fetch("gh"), definitionNode("p", .scheduled(.every(60)), from: ["gh"], deliver: .report),
    ])
    now += 120
    try runner.flow(id, to: .node(store.nodeId(id, "gh")))
    finish("gh", "")
    XCTAssertEqual(calls("p"), [], "前提: 過ぎていた p の予定の回は、取る行が 0 件なので手段を起こさない")
    try runner.flow(id, to: .node(store.nodeId(id, "gh")))
    finish("gh", fetched(["a"]))
    now += 10
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.name = "直した"
    let output = { (script: String, _: [String]) in
      script == "gh" ? self.fetched(["a"]) : "読んだ"
    }

    let start = jobs.calls.count
    let trial = try trials.start(
      try unsaved(.replace(id, version: current.version, rewrite)), .init())
    let tried = answer(from: start, until: { !trial.running }, output)
    XCTAssertNil(trial.failure)

    let writing = jobs.calls.count
    _ = try runner.set(id, version: current.version, rewrite)
    XCTAssertEqual(jobs.calls.count, writing, "前提: 本番では書いた時点に何も起きない")
    try runner.flow(id, to: .ends)
    let written = answer(from: writing, output)
    XCTAssertEqual(written["p"], [[downstream("gh", "a", of: id)]], "前提: 流しで a を読む")
    XCTAssertEqual(tried["p"], written["p"])
    XCTAssertEqual(trial.passes(key: "p").map(\.atWrite), [false])
  }

  /// 試走は、書いた時点の起こしが、止めるノードの引き取った 1 回を挟んで続いても、その途中で流し始めない。過ぎていた予定の回が何も
  /// 変えずに終わり、その下流のやり直しで、読み残しのある副作用と、読み残しのある「届いたら」の x が続けて起きる。このとき x は、
  /// 本番と同じく書いた時点の回と流しの回に分かれて読み、書いた時点の回だけが `atWrite` を持つ。
  func testARewriteDoesNotFlowInTheMiddleOfTheWakesAtWriting() throws {
    let id = try define([
      fetch("gh"), definitionNode("p", .scheduled(.every(60)), from: ["gh"]),
      definitionNode("se", .arrival, from: ["p"], deliver: .sideEffect),
      definitionNode("x", .arrival, from: ["gh", "p"], deliver: .report),
    ])
    try runner.flow(id, to: .ends)
    _ = answer(from: 0, failing: ["se", "x"], echo(["a"]))
    let fetching = jobs.calls.count
    try runner.flow(id, to: .node(store.nodeId(id, "gh")))
    _ = answer(from: fetching, failing: ["se", "x"], echo(["a", "b"]))
    now += 61
    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.name = "直した"
    let output = { (script: String, _: [String]) in
      script == "gh" ? self.fetched(["a", "b", "x"]) : ""
    }

    let start = jobs.calls.count
    let trial = try trials.start(
      try unsaved(.replace(id, version: current.version, rewrite)), .init(rows: [item("x")]))
    let tried = answer(from: start, until: { !trial.running }, output)
    XCTAssertNil(trial.failure)

    let writing = jobs.calls.count
    _ = try runner.set(id, version: current.version, rewrite)
    var written = answer(from: writing, output)
    let flowing = jobs.calls.count
    try runner.flow(id, to: .ends)
    written.merge(answer(from: flowing, output)) { $0 + $1 }
    XCTAssertEqual(written["x"]?.count, 2, "前提: 本番では x が書いた時点の回と流しの回の 2 回に分かれて読む")
    XCTAssertEqual(tried["x"], written["x"])
    XCTAssertEqual(trial.passes(key: "x").reversed().map(\.atWrite), [true, false])
  }
}
