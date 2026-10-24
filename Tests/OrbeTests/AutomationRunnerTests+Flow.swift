import XCTest

@testable import Orbe

/// 流す——部品を指し、そこに至る道の上で、普段なら今すぐ動かない部品（入力の無い部品と、間隔・cron・手動の入力のある部品）を
/// 上流の後に 1 回ずつ起こす。「届いたら」の部品は普段の決まりだけで動き、指した部品が終わったら一巡が終わる。
///
/// 壊れると何が起きるか: 毎朝 9:00 の判定を押しても取得しか走らない。道の外の部品が押したことで走る。手動の部品が上流の
/// 確定で勝手に走る。押した後に積まれた行を取らない回や、確定の前の回を一巡の分に数えて、下流を欠けた入力で走らせる。一巡が
/// 終わらず、Orbe を再起動するまでその自動化を二度と流せない。
extension AutomationRunnerTests {
  private static let far: TimeInterval = 86400 * 7

  private func flow(_ id: Int, to target: AutomationFlow.Target = .ends) throws {
    try runner.flow(id, to: target)
  }

  /// もう一度流すと流している途中で断られるか。断られなければ、そこで新しい一巡が始まっている。
  private func refusesAnotherFlow(_ id: Int) -> Bool {
    do throws(AutomationError) {
      try runner.flow(id, to: .ends)
    } catch {
      return error == .flowing(id)
    }
    return false
  }

  private func lastTrigger(_ key: String, of id: Int) -> AutomationPartRun.Trigger? {
    store.automation(id)?.state(key: key).runs.first?.trigger
  }

  /// 取得 `f` → 処理 `p`（手動）→ 副作用 `s1`（遠い予定）、`f` → 副作用 `s2`（遠い予定）、`p` → 副作用 `s3`（届いたら）。
  private func defineFanOut() throws -> Int {
    try define([
      fetch("f", every: 3600),
      part("p", .manual, from: ["f"]),
      part("s1", .scheduled(.every(Self.far)), from: ["p"], deliver: .sideEffect),
      part("s2", .scheduled(.every(Self.far)), from: ["f"], deliver: .sideEffect),
      part("s3", .arrival, from: ["p"], deliver: .sideEffect),
    ])
  }

  // MARK: - 道

  /// 指した部品の道の上の部品だけが上流の後に順に 1 回ずつ走り、指した部品が終わると一巡が終わる。道の外の部品は走らず、
  /// 道の上の「届いたら」は上流が積んだことで普段どおり起きる。
  func testFlowingToAPartRunsItsPathInOrderOnceAndLeavesTheRestAlone() throws {
    let id = try defineFanOut()

    try flow(id, to: .part(store.part(id, "s1")))
    XCTAssertEqual(calls("f").count, 1)
    XCTAssertEqual(calls("p"), [], "上流が終わるまで起こさない")
    finish("f", fetched(["a"]))
    XCTAssertEqual(calls("p").count, 1)
    XCTAssertEqual(calls("s1"), [])
    XCTAssertTrue(refusesAnotherFlow(id))
    finish("p", printed(#"{"id":"\#(downstream("f", "a", of: id))","note":"処理した"}"#))

    XCTAssertEqual(ids("s1"), [downstream("f", "a", of: id)])
    XCTAssertEqual(ids("s3"), [downstream("f", "a", of: id)], "届いたらは上流が積んだので普段どおり起きる")
    XCTAssertEqual(calls("s2"), [], "道の外は走らない")
    XCTAssertEqual(pending("s2", of: id), 1, "道の外の部品にも普段どおり読めば取る行が増える")
    XCTAssertTrue(refusesAnotherFlow(id))
    finish("s1", printed(""))

    XCTAssertEqual(calls("f").count, 1)
    XCTAssertEqual(calls("p").count, 1)
    XCTAssertEqual(lastTrigger("f", of: id), .now)
    XCTAssertEqual(lastTrigger("p", of: id), .now)
    XCTAssertEqual(lastTrigger("s1", of: id), .now)
    XCTAssertFalse(refusesAnotherFlow(id), "指した部品が終われば一巡が終わる（届いたらの s3 は道の外）")
  }

  /// 指す先を省くと終わりの部品すべてまで流れ、道の上の「届いたら」が走り終えるまで一巡は終わらない。
  func testFlowingToTheEndsRunsEveryPartAndWaitsForArrivalParts() throws {
    let id = try defineFanOut()

    try flow(id)
    finish("f", fetched(["a"]))
    XCTAssertEqual(calls("s2").count, 1, "f だけを上流に持つ s2 は f の後に走る")
    finish("p", printed(#"{"id":"\#(downstream("f", "a", of: id))","note":"処理した"}"#))
    finish("s1", printed(""))
    finish("s2", printed(""))
    XCTAssertTrue(refusesAnotherFlow(id), "届いたらの s3 が走っている間は終わらない")
    finish("s3", printed(""))

    XCTAssertFalse(refusesAnotherFlow(id))
  }

  /// 上流が何も積まなくても一巡は終わる——「届いたら」は起きないまま、流しが起こした手動の部品は取る行が無いまま終わる。
  /// 止めた自動化も流せる。
  func testAFlowWhoseUpstreamAddsNothingStillEndsAndPausedAutomationsFlow() throws {
    let id = try define([
      fetch("f", every: 3600),
      part("digest", .arrival, from: ["f"], deliver: .report),
      part("p", .manual, from: ["f"], deliver: .report),
    ])
    _ = try runner.pause(id, true)

    try flow(id)
    finish("f", fetched([]))

    XCTAssertEqual(calls("digest"), [])
    XCTAssertFalse(refusesAnotherFlow(id))
  }

  /// 指す先が 1 つも無ければ（判定を持たない自動化の候補の更新）、何も起こさず一巡も置かない。置くと終わりの知らせが来ず、
  /// 以後ずっと断る。
  func testFlowingToNoPartsRunsNothingAndLeavesNoFlow() throws {
    let id = try define([
      fetch("f", every: 3600), part("s", .arrival, from: ["f"], deliver: .sideEffect),
    ])

    try flow(id, to: .judges)

    XCTAssertEqual(calls("f"), [])
    XCTAssertFalse(runner.isFlowing(id))
    XCTAssertFalse(refusesAnotherFlow(id))
  }

  // MARK: - 手動

  /// 手動の部品は上流が積んでも走らず、それ自身かその下流を指して流したときだけ走る。上流を指して流しても走らない。
  func testAManualPartRunsOnlyWhenItOrItsDownstreamIsFlowedTo() throws {
    let id = try define([
      fetch("f", every: 1800),
      part("p", .manual, from: ["f"], deliver: .report),
    ])
    advance(by: 1800)
    finish("f", fetched(["a"]))
    advance(by: 86400)
    XCTAssertEqual(calls("p"), [], "予定でも上流の確定でも走らない")
    finish("f", fetched(["a"]))

    try flow(id, to: .part(store.part(id, "f")))
    finish("f", fetched(["a", "b"]))
    XCTAssertEqual(calls("p"), [], "上流を指して流しても走らない")

    try flow(id, to: .part(store.part(id, "p")))
    finish("f", fetched(["a", "b"]))
    XCTAssertEqual(ids("p"), [downstream("f", "a", of: id), downstream("f", "b", of: id)])
  }

  // MARK: - 走っている回

  /// 流し始めに走っている入力の無い部品は、その回を一巡の分にして重ねて起こさない。上流が終わった時点で走っている入力の
  /// ある部品は、その回が押した後の行を取れないので、終わった後にもう 1 回起こす。
  func testARunningSourceCountsButARunningPartWithInputsRunsOnceMoreAfterIt() throws {
    let id = try define([
      fetch("f", every: 3600),
      part("j", .scheduled(.every(3600)), from: ["f"], deliver: .report),
    ])
    advance(by: 3600)
    finish("f", fetched(["a"]))
    advance(by: 3600)
    XCTAssertEqual(ids("j"), [downstream("f", "a", of: id)], "前提: j が予定で走っている")
    XCTAssertEqual(calls("f").count, 2, "前提: f が予定で走っている")

    try flow(id)
    XCTAssertEqual(calls("f").count, 2, "走っている f を一巡の分にする")
    finish("f", fetched(["a", "b"]))
    XCTAssertEqual(calls("j").count, 1, "走っている j の終わりを待つ")
    finish("j", printed("要約"))

    XCTAssertEqual(calls("j").count, 2)
    XCTAssertEqual(ids("j"), [downstream("f", "b", of: id)], "押した後に積まれた行を取る")
    XCTAssertTrue(refusesAnotherFlow(id))
    finish("j", printed("要約"))
    XCTAssertFalse(refusesAnotherFlow(id))
  }

  /// 待っていた回の終わりの中で番人が次の予定の回を始めたら、その回を一巡の分にする。古い回の終わりを一巡の分の終わりと
  /// 取り違えない。
  func testAScheduledRunStartedInsideTheBlockingRunsEndIsTheFlowsRun() throws {
    let id = try define([
      fetch("f", every: 3600),
      part("j", .scheduled(.every(600)), from: ["f"], deliver: .report),
    ])
    advance(by: 3600)
    finish("f", fetched(["a"]))
    advance(by: 600)
    XCTAssertEqual(ids("j"), [downstream("f", "a", of: id)], "前提: j が予定で走っている")

    try flow(id)
    finish("f", fetched(["a", "b"]))
    advance(by: 600)
    XCTAssertEqual(calls("j").count, 1, "前提: 走っている間は重ねない")
    finish("j", printed("要約"))

    XCTAssertEqual(calls("j").count, 2, "予定の回が続けて始まり、流しは重ねて起こさない")
    XCTAssertEqual(ids("j"), [downstream("f", "b", of: id)])
    XCTAssertTrue(refusesAnotherFlow(id), "古い回の終わりで一巡を進めない")
    finish("j", printed("要約"))
    XCTAssertEqual(calls("j").count, 2)
    XCTAssertEqual(lastTrigger("j", of: id), .schedule)
    XCTAssertFalse(refusesAnotherFlow(id))
  }

  // MARK: - 予定の書き換え

  /// 取得 `f` → `a`（予定は `trigger`）→ 報告 `s`（手動）。
  private func chain(a trigger: AutomationPart.Trigger) -> AutomationDefinition {
    AutomationDefinition(
      name: "流す", notify: nil,
      parts: [
        fetch("f", every: 3600),
        part("a", trigger, from: ["f"]),
        part("s", .manual, from: ["a"], deliver: .report),
      ])
  }

  /// 流しの途中で道の上の部品を「届いたら」から間隔に変えると、今の予定で決める——上流の後に流しが 1 回起こしてから下流へ進む。
  func testAPartTurnedFromArrivalToIntervalMidFlowIsWokenByTheFlow() throws {
    let id = try runner.set(nil, chain(a: .arrival)).id
    try flow(id)
    try rewrite(id, chain(a: .scheduled(.every(86400))))
    finish("f", fetched(["x"]))

    XCTAssertEqual(ids("a"), [downstream("f", "x", of: id)], "上流の後に流しが起こす")
    XCTAssertEqual(calls("s"), [], "a が終わるまで下流へ進まない")
    finish("a", printed(#"{"id":"\#(downstream("f", "x", of: id))","note":"処理した"}"#))
    XCTAssertEqual(lastTrigger("a", of: id), .now)
    XCTAssertEqual(ids("s"), [downstream("f", "x", of: id)])
    XCTAssertTrue(refusesAnotherFlow(id))
    finish("s", printed("要約"))
    XCTAssertFalse(refusesAnotherFlow(id))
  }

  /// 流しの途中で道の上の部品を間隔から「届いたら」に変えると、流しはそれを起こさず普段の決まりに任せる——上流が積んで
  /// 起きた回が失敗しても、同じ行ですぐ起こし直さず、終わりと数えて下流へ進む。
  func testAPartTurnedFromIntervalToArrivalMidFlowIsLeftToItsUsualRule() throws {
    let id = try runner.set(nil, chain(a: .scheduled(.every(86400)))).id
    try flow(id)
    try rewrite(id, chain(a: .arrival))
    finish("f", fetched(["x"]))
    XCTAssertEqual(ids("a"), [downstream("f", "x", of: id)], "前提: 上流が積んだので普段どおり起きる")
    finish("a", printed("", exit: 1))

    XCTAssertEqual(calls("a").count, 1, "失敗した行で流しが起こし直さない")
    XCTAssertEqual(lastTrigger("a", of: id), .arrival)
    XCTAssertFalse(refusesAnotherFlow(id), "a を終わりと数え、取る行の無い s で一巡が終わる")
  }

  // MARK: - 打ち切り

  /// 道の上の部品の入力を書き換えると（道の形が変わる）一巡は打ち切られ、また流せる。
  func testRewritingTheInputsOfAPartOnThePathAbortsTheFlow() throws {
    func definition(a inputs: [String]) -> AutomationDefinition {
      AutomationDefinition(
        name: "流す", notify: nil,
        parts: [
          fetch("f", every: 3600), fetch("g", every: 3600),
          part("a", .manual, from: inputs, deliver: .report),
          part("b", .manual, from: ["g"], deliver: .report),
        ])
    }
    let id = try runner.set(nil, definition(a: ["f", "g"])).id
    try flow(id, to: .part(store.part(id, "a")))
    try rewrite(id, definition(a: ["f"]))

    try flow(id, to: .part(store.part(id, "a")))
  }

  /// 道の上の部品の何をするかを書き換えると一巡は打ち切られ、また流せる。道に触れない書き換え（名前）では続く。
  func testRewritingAPartOnThePathAbortsTheFlowButRenamingDoesNot() throws {
    func definition(_ name: String, f script: String) -> AutomationDefinition {
      AutomationDefinition(
        name: name, notify: nil,
        parts: [
          fetch("f", every: 3600, script: script),
          part("j", .manual, from: ["f"], deliver: .report),
        ])
    }
    let id = try runner.set(nil, definition("流す", f: "f")).id
    try flow(id)

    try rewrite(id, definition("流す（改名）", f: "f"))
    XCTAssertTrue(refusesAnotherFlow(id))
    try rewrite(id, definition("流す（改名）", f: "f --all"))

    try flow(id)
    XCTAssertEqual(calls("f --all").count, 1)
  }

  // MARK: - 観測

  /// 一巡の有無を読んだ側に、変化が届くか（届いたら true）。
  @MainActor private func flowingChanges(_ id: Int, _ change: () throws -> Void) rethrows -> Bool {
    var changed = false
    withObservationTracking {
      _ = runner.isFlowing(id)
    } onChange: {
      changed = true
    }
    try change()
    return changed
  }

  /// ⌘⇧X の棚の「更新中…」は一巡の有無を観測して描く。一巡を置く・終わる・打ち切るのどれでも変化が届き、流していない
  /// 部品の回だけでは届かない。
  ///
  /// 壊れると何が起きるか。「更新中…」が出ない・終わっても消えない。予定どおりの回のたびに提案タブが描き直される。
  @MainActor func testFlowingIsObservableAndRunsOutsideAFlowAreNot() throws {
    let id = try define([
      fetch("f", every: 3600), part("j", .manual, from: ["f"], deliver: .taskCandidates),
    ])

    XCTAssertFalse(
      flowingChanges(id) {
        advance(by: 3600)
        finish("f", fetched(["a"]))
      }, "流していない回")
    XCTAssertTrue(try flowingChanges(id) { try flow(id, to: .judges) }, "置く")
    finish("f", fetched(["b"]))
    XCTAssertTrue(flowingChanges(id) { finish("j", printed("")) }, "終わる")
    XCTAssertFalse(runner.isFlowing(id))
    try flow(id, to: .judges)
    XCTAssertTrue(try flowingChanges(id) { try runner.delete(id) }, "打ち切る")
    XCTAssertFalse(runner.isFlowing(id))
  }
}
