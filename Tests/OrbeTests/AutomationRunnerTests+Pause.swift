import XCTest

@testable import Orbe

/// 止める——自動化かノードを止めると、Orbe は実効で止めたノードを自分からは動かさない（予定の時刻でも、起こす決まりでも）。
/// 明示の実行（流し）は止めず、道の上の止めたノードも 1 回動かす。流しは道が重なるものだけを断る。
///
/// 壊れると何が起きるか: 止めたノードが時刻や上流の行で動き続ける。止めている間に積もった行が再開で読まれない。自動化を再開すると
/// 個別に止めたノードまで動き出す。止めた「届いたら」のノードを流すと一巡が終わらず、以後その自動化を流せない。棚の更新が、
/// 判定に触れない流しの間も断られる。外したノードを通らない流しまで打ち切られる。
extension AutomationRunnerTests {
  private func trigger(_ key: String, of id: Int) -> AutomationNodeRun.Trigger? {
    store.automation(id)?.state(key: key).runs.first?.trigger
  }

  private func flowRefusal(_ id: Int, to target: AutomationFlow.Target) -> AutomationNodeID? {
    do throws(AutomationError) {
      try runner.flow(id, to: target)
    } catch {
      if case .flowing(id, let nodeId) = error { return nodeId }
      XCTFail("\(error)")
    }
    return nil
  }

  /// 止めた間隔のノードは時刻が来ても回らず、止めた「届いたら」のノードは上流が行を出しても起きずに未処理が積もる。ほかのノードは
  /// 予定どおり回る。再開すると、積もった行をまとめて読み、過ぎた間隔の回は 1 回すぐ回る。止める・再開で版は変わらない。
  func testAPausedNodeNeitherRunsOnScheduleNorWakesAndResumingCatchesUp() throws {
    let id = try define([
      fetch("a", every: 60),
      definitionNode("b", .arrival, from: ["a"], deliver: .sideEffect),
      fetch("c", every: 60),
      definitionNode("d", .arrival, from: ["c"], deliver: .sideEffect),
    ])
    let (b, c) = (store.nodeId(id, "b"), store.nodeId(id, "c"))
    _ = try runner.pause(id, nodeId: b, true)
    _ = try runner.pause(id, nodeId: c, true)
    let version = store.automation(id)?.version

    advance(by: 60)
    XCTAssertEqual(calls("c"), [], "止めた間隔のノードは時刻が来ても回らない")
    finish("a", fetched(["x"]))
    advance(by: 60)
    finish("a", fetched(["y"]))
    XCTAssertEqual(calls("b"), [], "止めた届いたらのノードは上流が行を出しても起きない")
    XCTAssertEqual(pending("b", of: id), 2)
    let automation = try XCTUnwrap(store.automation(id))
    XCTAssertEqual(automation.state(key: "b").paused, true)
    XCTAssertNil(runner.nextRunAt(automation, nodeId: c), "止めたノードは次回に数えない")
    XCTAssertNotNil(runner.nextRunAt(automation, nodeId: store.nodeId(id, "a")))

    _ = try runner.pause(id, nodeId: b, false)
    XCTAssertEqual(ids("b"), [downstream("a", "x", of: id), downstream("a", "y", of: id)])
    _ = try runner.pause(id, nodeId: c, false)
    XCTAssertEqual(calls("c").count, 1, "過ぎた間隔の回は再開で 1 回すぐ回る")
    XCTAssertEqual(store.automation(id)?.version, version)
  }

  /// 自動化の印とノードの印は別に持つ。自動化を再開しても個別に止めたノードは止まったまま、個別に止めたノードを再開しても自動化を
  /// 止めていれば動かない。
  func testTheAutomationsMarkAndTheNodesMarkAreSeparate() throws {
    let id = try define([
      fetch("a", every: 60),
      definitionNode("b", .arrival, from: ["a"], deliver: .sideEffect),
    ])
    let b = store.nodeId(id, "b")
    _ = try runner.pause(id, nodeId: b, true)
    _ = try runner.pause(id, true)
    _ = try runner.pause(id, false)
    advance(by: 60)
    finish("a", fetched(["x"]))
    XCTAssertEqual(calls("b"), [], "自動化を再開しても個別に止めたノードは止まったまま")

    _ = try runner.pause(id, true)
    _ = try runner.pause(id, nodeId: b, false)
    XCTAssertEqual(calls("b"), [], "自動化を止めていればノードを再開しても動かない")
    _ = try runner.pause(id, false)
    XCTAssertEqual(ids("b"), [downstream("a", "x", of: id)])
  }

  /// 止めた自動化でも流せる。上流を流しても道の外の「届いたら」は起きず、止めた「届いたら」を指して流すと、上流の後に 1 回起き、
  /// 一巡が終わる。
  func testAPausedAutomationFlowsOnlyAlongThePath() throws {
    let id = try define([
      fetch("a", every: 86400),
      definitionNode("b", .arrival, from: ["a"], deliver: .sideEffect),
    ])
    _ = try runner.pause(id, true)

    try runner.flow(id, to: .node(store.nodeId(id, "a")))
    finish("a", fetched(["x"]))
    XCTAssertEqual(calls("b"), [], "道の外の届いたらは起きない")
    XCTAssertFalse(runner.isFlowing(id))

    try runner.flow(id, to: .node(store.nodeId(id, "b")))
    XCTAssertEqual(calls("b"), [], "上流が終わるまで起こさない")
    finish("a", fetched(["y"]))
    XCTAssertEqual(ids("b"), [downstream("a", "x", of: id), downstream("a", "y", of: id)])
    finish("b", printed(""))
    XCTAssertEqual(trigger("b", of: id), .now)
    XCTAssertFalse(runner.isFlowing(id), "止めた届いたらを起こした一巡も終わる")
  }

  /// 道の重ならない流しは同時に走り、重なる流しは重なったノード（定義の順で最初）を言って断る。外したノードを通る流しだけが
  /// 打ち切られ、ほかの流しは続く。
  func testFlowsWhosePathsDoNotMeetRunTogether() throws {
    let id = try define([
      fetch("a", every: 86400),
      definitionNode("b", .manual, from: ["a"], deliver: .sideEffect),
      fetch("c", every: 86400),
      definitionNode("d", .manual, from: ["c"], deliver: .sideEffect),
    ])
    let (a, b, c, d) = (
      store.nodeId(id, "a"), store.nodeId(id, "b"), store.nodeId(id, "c"), store.nodeId(id, "d")
    )

    try runner.flow(id, to: .node(d))
    try runner.flow(id, to: .node(b))
    XCTAssertEqual(calls("a").count, 1)
    XCTAssertEqual(calls("c").count, 1)
    XCTAssertEqual(flowRefusal(id, to: .node(d)), c)
    XCTAssertEqual(flowRefusal(id, to: .ends), a)
    XCTAssertTrue(runner.isFlowing(id, through: [d]))

    let current = try XCTUnwrap(store.automation(id)?.definition)
    try rewrite(
      id,
      AutomationDefinition(
        name: current.name, notify: nil,
        nodes: current.nodes.filter { ["a", "b"].contains($0.key) }))
    XCTAssertFalse(runner.isFlowing(id, through: [c, d]), "外したノードを通る流しだけが打ち切られる")
    XCTAssertTrue(runner.isFlowing(id, through: [b]))
    finish("a", fetched(["x"]))
    finish("b", printed(""))
    XCTAssertFalse(runner.isFlowing(id))
  }

  /// 取得 `f` → 届いたらの `a` → 手動の報告 `s`。
  private func chain() throws -> Int {
    try define([
      fetch("f", every: 3600),
      definitionNode("a", .arrival, from: ["f"]),
      definitionNode("s", .manual, from: ["a"], deliver: .report),
    ])
  }

  /// 流しの途中で道の上の「届いたら」を止めると、上流の後に流しが 1 回起こして下流へ進み、一巡が終わる（起こすか見届けるかを
  /// 知らせのたびに今の状態で決める）。
  func testAnArrivalNodePausedMidFlowIsWokenByTheFlow() throws {
    let id = try chain()
    try runner.flow(id, to: .ends)
    _ = try runner.pause(id, nodeId: store.nodeId(id, "a"), true)
    finish("f", fetched(["x"]))

    XCTAssertEqual(ids("a"), [downstream("f", "x", of: id)])
    XCTAssertEqual(trigger("a", of: id), nil, "前提: まだ記録が無い")
    finish("a", printed(#"{"id":"\#(downstream("f", "x", of: id))"}"#))
    XCTAssertEqual(trigger("a", of: id), .now, "流しが起こした回")
    finish("s", printed("要約"))
    XCTAssertFalse(runner.isFlowing(id))
  }

  /// 流しが見届けている「届いたら」の回の途中でそのノードを止めても、その回が上流の最後の行まで読んでいれば、見届けた回を
  /// 一巡の分に数える——失敗で終えても同じ行で起こし直さない。
  func testAWatchedRunPausedMidwayCountsForTheFlowEvenWhenItFails() throws {
    let id = try chain()
    try runner.flow(id, to: .ends)
    finish("f", fetched(["x"]))
    XCTAssertEqual(calls("a").count, 1, "前提: 上流が積んだので普段どおり起きる")
    _ = try runner.pause(id, nodeId: store.nodeId(id, "a"), true)
    finish("a", printed("", exit: 1))

    XCTAssertEqual(calls("a").count, 1, "失敗した行で流しが起こし直さない")
    XCTAssertFalse(runner.isFlowing(id), "a を終わりと数え、取る行の無い s で一巡が終わる")
  }

  /// 流しの前から走っていた「届いたら」の回を止めると、その回は流しの後に上流が出した行を読んでいないので、回の終わりに流しが
  /// 1 回起こし、その行を読む。
  func testARunFromBeforeTheFlowPausedMidwayIsFollowedByAFlowedRun() throws {
    let id = try chain()
    advance(by: 3600)
    finish("f", fetched(["x"]))
    XCTAssertEqual(calls("a").count, 1, "前提: 流しの前から a が走っている")
    try runner.flow(id, to: .ends)
    _ = try runner.pause(id, nodeId: store.nodeId(id, "a"), true)
    finish("f", fetched(["y"]))
    finish("a", printed(#"{"id":"\#(downstream("f", "x", of: id))"}"#))

    XCTAssertEqual(calls("a").count, 2, "流しの後の行を読む回を起こす")
    XCTAssertEqual(ids("a"), [downstream("f", "y", of: id)])
  }
}
