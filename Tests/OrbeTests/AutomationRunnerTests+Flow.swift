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
    store.automation(id)?.state(key).runs.first?.trigger
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

    try flow(id, to: .part("s1"))
    XCTAssertEqual(calls("f").count, 1)
    XCTAssertEqual(calls("p"), [], "上流が終わるまで起こさない")
    finish("f", fetched(["a"]))
    XCTAssertEqual(calls("p").count, 1)
    XCTAssertEqual(calls("s1"), [])
    XCTAssertTrue(refusesAnotherFlow(id))
    finish("p", printed(#"{"id":"f:a","note":"処理した"}"#))

    XCTAssertEqual(ids("s1"), ["f:a"])
    XCTAssertEqual(ids("s3"), ["f:a"], "届いたらは上流が積んだので普段どおり起きる")
    XCTAssertEqual(calls("s2"), [], "道の外は走らない")
    XCTAssertEqual(inbox("s2", of: id), 1, "道の外の溜まりは普段どおり溜まる")
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
    finish("p", printed(#"{"id":"f:a","note":"処理した"}"#))
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

    try flow(id, to: .part("f"))
    finish("f", fetched(["a", "b"]))
    XCTAssertEqual(calls("p"), [], "上流を指して流しても走らない")

    try flow(id, to: .part("p"))
    finish("f", fetched(["a", "b"]))
    XCTAssertEqual(ids("p"), ["f:a", "f:b"])
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
    XCTAssertEqual(ids("j"), ["f:a"], "前提: j が予定で走っている")
    XCTAssertEqual(calls("f").count, 2, "前提: f が予定で走っている")

    try flow(id)
    XCTAssertEqual(calls("f").count, 2, "走っている f を一巡の分にする")
    finish("f", fetched(["a", "b"]))
    XCTAssertEqual(calls("j").count, 1, "走っている j の終わりを待つ")
    finish("j", printed("要約"))

    XCTAssertEqual(calls("j").count, 2)
    XCTAssertEqual(ids("j"), ["f:b"], "押した後に積まれた行を取る")
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
    XCTAssertEqual(ids("j"), ["f:a"], "前提: j が予定で走っている")

    try flow(id)
    finish("f", fetched(["a", "b"]))
    advance(by: 600)
    XCTAssertEqual(calls("j").count, 1, "前提: 走っている間は重ねない")
    finish("j", printed("要約"))

    XCTAssertEqual(calls("j").count, 2, "予定の回が続けて始まり、流しは重ねて起こさない")
    XCTAssertEqual(ids("j"), ["f:b"])
    XCTAssertTrue(refusesAnotherFlow(id), "古い回の終わりで一巡を進めない")
    finish("j", printed("要約"))
    XCTAssertEqual(calls("j").count, 2)
    XCTAssertEqual(lastTrigger("j", of: id), .schedule)
    XCTAssertFalse(refusesAnotherFlow(id))
  }

  // MARK: - 打ち切り

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

    _ = try runner.set(id, definition("流す（改名）", f: "f"))
    XCTAssertTrue(refusesAnotherFlow(id))
    _ = try runner.set(id, definition("流す（改名）", f: "f --all"))

    try flow(id)
    XCTAssertEqual(calls("f --all").count, 1)
  }
}
