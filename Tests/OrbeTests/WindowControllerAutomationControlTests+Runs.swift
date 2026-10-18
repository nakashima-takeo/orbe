import XCTest

@testable import Orbe

/// 一覧の部品の回の記録——保存の形（取った件数・実行の記録・役割ごとの結果）に、AI が読む英文（終わり方・失敗・外れた行・
/// 捨てた案）を添えた形で出ること。
///
/// 壊れると何が起きるか: 回の記録を読む AI・秘書が、部品ごとの件数や結果を読めなくなる。失敗や外れた行の英文が黙って変わるか
/// 消え、AI がなぜ失敗したかを読めずに定義を直せない。
extension WindowControllerAutomationControlTests {
  /// 一覧の回の記録は部品ごとに、保存の形（取った件数・実行の記録・役割ごとの結果）を持つ。
  func testListedRunsKeepTheStoredShape() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition())
    let a = Self.item("a")
    try Self.round(wc.automationStore, id, fetched: [a], proposing: [a])

    let parts = try XCTUnwrap(try listed(wc)[id]?["parts"] as? [String: [String: Any]])
    let judged = try XCTUnwrap((parts["judge"]?["runs"] as? [[String: Any]])?.first)

    XCTAssertEqual(
      Set(judged.keys), ["startedAt", "endedAt", "trigger", "taken", "execution", "result"])
    XCTAssertEqual(judged["taken"] as? Int, 1)
    XCTAssertEqual((judged["execution"] as? [String: Any])?["commandLine"] as? String, "claude -p")
    let result = try XCTUnwrap(judged["result"] as? [String: Any])
    XCTAssertEqual(result["kind"] as? String, "judge")
    XCTAssertEqual(result["proposed"] as? Int, 1)
    XCTAssertEqual(parts["judge"]?["inbox"] as? Int, 0)
    XCTAssertNil(parts["fetch"]?["inbox"], "入力の無い部品は溜まりを持たない")

    let fetched = try XCTUnwrap((parts["fetch"]?["runs"] as? [[String: Any]])?.first)
    XCTAssertEqual(
      Set(fetched.keys),
      ["startedAt", "endedAt", "trigger", "execution", "result", "stacked", "withdrawn"])
    XCTAssertEqual((fetched["execution"] as? [String: Any])?["count"] as? Int, 1)
    XCTAssertEqual(fetched["stacked"] as? Int, 1)
    let fetchResult = try XCTUnwrap(fetched["result"] as? [String: Any])
    XCTAssertEqual(fetchResult["kind"] as? String, "fetch")
    XCTAssertEqual(fetchResult["fresh"] as? Int, 1)
  }

  /// 失敗・外れた行・判定の確定で捨てた案は、保存した種類に、AI が読む英文（部品の鍵入り）を添えて出る。英文は今までと
  /// 一字一句同じ。
  func testListedRunsSpellFailuresRejectedLinesAndDismissalsInEnglish() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition())
    let store = wc.automationStore
    let start = Date()
    func record(_ part: String, at offset: TimeInterval, _ outcome: AutomationPartPass.Outcome)
      throws
    {
      let at = start.addingTimeInterval(offset)
      _ = try store.record(
        AutomationPassEnd(
          automationId: id, part: part, trigger: .schedule, startedAt: at, endedAt: at,
          take: part == "judge" ? AutomationInbox.Take(taken: [], dropped: []) : nil,
          outcome: outcome))
    }
    try record(
      "fetch", at: 0,
      .failed(
        .ended(detail: "boom"), DesignSceneFixtures.execution(0, ending: .timeLimit),
        breach: nil))
    try record(
      "fetch", at: 1,
      .failed(
        .brokeRules, DesignSceneFixtures.execution(0),
        breach: AutomationPartPass.Breach(
          lines: [AutomationBrokenLine(line: 3, fault: .missingKey("link"))],
          redo: AutomationPartPass.Redo(
            firstCall: DesignSceneFixtures.execution(0),
            lines: [AutomationBrokenLine(line: 2, fault: .notJSON)]))))
    try record(
      "judge", at: 2,
      .succeeded(
        .judge(proposals: [], resolved: ["https://example.com/gone"]),
        DesignSceneFixtures.execution(0), breach: nil))

    let parts = try XCTUnwrap(try listed(wc)[id]?["parts"] as? [String: [String: Any]])
    let fetches = try XCTUnwrap(parts["fetch"]?["runs"] as? [[String: Any]])
    XCTAssertEqual(fetches.count, 2, "前提")
    let (broke, ended) = (fetches[0], fetches[1])

    XCTAssertEqual(
      ended["failure"] as? String, #"the part "fetch" ended: stopped at the time limit: boom"#)
    XCTAssertEqual(
      (ended["execution"] as? [String: Any])?["ending"] as? String, "stopped at the time limit")
    XCTAssertEqual((ended["failed"] as? [String: Any])?["kind"] as? String, "ended", "種類も出る")

    XCTAssertEqual(
      broke["failure"] as? String, #"the output of part "fetch" broke the rules: line 2: not JSON"#,
      "出し直しても外れた行で言う")
    let breach = try XCTUnwrap(broke["breach"] as? [String: Any])
    XCTAssertEqual(
      (breach["lines"] as? [String: Any])?["reasons"] as? [String], ["line 3: missing link"])
    XCTAssertEqual(
      ((breach["redo"] as? [String: Any])?["lines"] as? [String: Any])?["reasons"] as? [String],
      ["line 2: not JSON"])

    let judged = try XCTUnwrap((parts["judge"]?["runs"] as? [[String: Any]])?.first)
    let rejected = try XCTUnwrap(
      (judged["result"] as? [String: Any])?["rejected"] as? [String: Any])
    XCTAssertEqual(rejected["count"] as? Int, 1)
    XCTAssertEqual(
      rejected["reasons"] as? [String], ["resolve https://example.com/gone: no open proposal"])
  }
}
