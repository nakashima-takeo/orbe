import XCTest

@testable import Orbe

/// 部品の回の記録——一覧の最新の 1 回（`lastRun`）と、過去の回のページ読み（`list_automation_runs`）が、保存の形（取った件数・
/// 実行の記録・役割ごとの結果）に AI が読む英文（終わり方・失敗・外れた行・捨てた案）を添えた形で出ること。
///
/// 壊れると何が起きるか: 回の記録を読む AI・秘書が、部品ごとの件数や結果を読めなくなる。失敗や外れた行の英文が黙って変わるか
/// 消え、AI がなぜ失敗したかを読めずに定義を直せない。一覧が全部品の過去の回を載せて AI の文脈を圧迫する、または過去の回を
/// 読めない。
extension WindowControllerAutomationControlTests {
  /// 一覧の回の記録は部品ごとに、保存の形（取った件数・実行の記録・役割ごとの結果）を持つ。
  func testListedRunsKeepTheStoredShape() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition())
    let a = Self.item("a")
    try Self.round(wc.automationStore, id, fetched: [a], proposing: [a])

    let nodes = try XCTUnwrap(try listed(wc)[id]?["nodes"] as? [String: [String: Any]])
    let judged = try XCTUnwrap(nodes["judge"]?["lastRun"] as? [String: Any])

    XCTAssertNil(nodes["judge"]?["runs"], "一覧は最新の 1 回だけ")
    XCTAssertEqual(
      Set(judged.keys),
      ["recordId", "startedAt", "endedAt", "trigger", "taken", "execution", "result"])
    XCTAssertEqual(judged["taken"] as? Int, 1)
    XCTAssertEqual((judged["execution"] as? [String: Any])?["commandLine"] as? String, "claude -p")
    let result = try XCTUnwrap(judged["result"] as? [String: Any])
    XCTAssertEqual(result["kind"] as? String, "judge")
    XCTAssertEqual(result["proposed"] as? Int, 1)
    XCTAssertEqual(nodes["judge"]?["pending"] as? Int, 0)
    XCTAssertNil(nodes["fetch"]?["pending"], "入力の無い部品は読めば取る行を持たない")

    let fetched = try XCTUnwrap(nodes["fetch"]?["lastRun"] as? [String: Any])
    XCTAssertEqual(
      Set(fetched.keys),
      ["recordId", "startedAt", "endedAt", "trigger", "execution", "result", "withdrawn"])
    XCTAssertEqual((fetched["execution"] as? [String: Any])?["count"] as? Int, 1)
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
    func record(_ nodeKey: String, at offset: TimeInterval, _ outcome: AutomationNodePass.Outcome)
      throws
    {
      try store.record(id, nodeKey: nodeKey, at: start.addingTimeInterval(offset), outcome: outcome)
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
        breach: AutomationRejections([
          AutomationBrokenLine(line: 3, fault: .missingKey("link")),
          AutomationBrokenLine(line: 4, fault: .notJSON),
        ])))
    try record(
      "judge", at: 2,
      .succeeded(
        .judge(proposals: [], resolved: ["https://example.com/gone"]),
        DesignSceneFixtures.execution(0), breach: nil))

    let fetches = try XCTUnwrap(
      success(
        wc.controlListAutomationRuns(automationId: id, nodeKey: "fetch", before: nil, limit: nil))[
          "runs"] as? [[String: Any]])
    XCTAssertEqual(fetches.count, 2, "前提")
    XCTAssertEqual(fetches.map { $0["nodeKey"] as? String }, ["fetch", "fetch"])
    let (broke, ended) = (fetches[0], fetches[1])

    XCTAssertEqual(
      ended["failure"] as? String, #"the node "fetch" ended: stopped at the time limit: boom"#)
    XCTAssertEqual(
      (ended["execution"] as? [String: Any])?["ending"] as? String, "stopped at the time limit")
    XCTAssertEqual((ended["failed"] as? [String: Any])?["kind"] as? String, "ended", "種類も出る")

    XCTAssertEqual(
      broke["failure"] as? String,
      #"the output of node "fetch" broke the rules: item 3: missing link"#, "最初の外れた件で言う")
    let breach = try XCTUnwrap(broke["breach"] as? [String: Any])
    XCTAssertEqual(breach["count"] as? Int, 2)
    XCTAssertEqual(
      breach["reasons"] as? [String], ["item 3: missing link", "item 4: not JSON"])

    let nodes = try XCTUnwrap(try listed(wc)[id]?["nodes"] as? [String: [String: Any]])
    let judged = try XCTUnwrap(nodes["judge"]?["lastRun"] as? [String: Any])
    let rejected = try XCTUnwrap(
      (judged["result"] as? [String: Any])?["rejected"] as? [String: Any])
    XCTAssertEqual(rejected["count"] as? Int, 1)
    XCTAssertEqual(
      rejected["reasons"] as? [String], ["resolve https://example.com/gone: no open proposal"])
  }

  /// 部品の外した印は、印の回の開始時刻・外れた件（英文つき）・その回が通ったかで出る。
  func testABreachMarkIsListedFromTheMarkedRun() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition())
    try wc.automationStore.record(
      id, nodeKey: "fetch", at: Date(),
      outcome: .failed(
        .brokeRules, DesignSceneFixtures.execution(0),
        breach: AutomationRejections([
          AutomationBrokenLine(line: 3, fault: .missingKey("link")),
          AutomationBrokenLine(line: 4, fault: .notJSON),
        ])))

    let fetch = try XCTUnwrap(
      try listed(wc)[id]?["nodes"] as? [String: [String: Any]])["fetch"]
    let mark = try XCTUnwrap(fetch?["breach"] as? [String: Any])
    let run = try XCTUnwrap(fetch?["lastRun"] as? [String: Any])
    XCTAssertEqual(Set(mark.keys), ["at", "lines", "passed"])
    XCTAssertEqual(mark["at"] as? String, run["startedAt"] as? String)
    let lines = try XCTUnwrap(mark["lines"] as? [String: Any])
    XCTAssertEqual(lines["count"] as? Int, 2)
    XCTAssertEqual(lines["reasons"] as? [String], ["item 3: missing link", "item 4: not JSON"])
    XCTAssertEqual(mark["passed"] as? Bool, false)
  }

  /// 過去の回は新しい順に `limit` 件ずつ読め、返した最後の記録の ID を `before` に渡すと続きが返る。部品を指せばその部品だけ。
  /// 部品ごとに残る回は 20 件。
  func testPastRunsArePagedNewestFirst() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition())
    let start = Date()
    for n in 0..<25 {
      let at = start.addingTimeInterval(TimeInterval(n))
      try wc.automationStore.record(
        id, nodeKey: "fetch", at: at, outcome: DesignSceneFixtures.fetched([]))
      try wc.automationStore.record(
        id, nodeKey: "judge", at: at, outcome: DesignSceneFixtures.judged([], rows: 0))
    }
    func page(_ before: Int?, limit: Int? = nil, nodeKey: String? = nil) throws -> [String: Any] {
      try success(
        wc.controlListAutomationRuns(
          automationId: id, nodeKey: nodeKey, before: before, limit: limit))
    }

    let first = try page(nil)
    let firstRuns = try XCTUnwrap(first["runs"] as? [[String: Any]])
    let next = try XCTUnwrap(first["next"] as? Int)
    let second = try page(next)
    let secondRuns = try XCTUnwrap(second["runs"] as? [[String: Any]])

    XCTAssertEqual(firstRuns.count, 20, "既定は 20 件")
    XCTAssertEqual(next, firstRuns.last?["recordId"] as? Int)
    XCTAssertEqual(secondRuns.count, 20)
    XCTAssertNil(second["next"])
    let ids = (firstRuns + secondRuns).compactMap { $0["recordId"] as? Int }
    XCTAssertEqual(ids, ids.sorted(by: >), "新しい順")
    XCTAssertEqual(Set(ids).count, 40, "部品ごとに 20 件")
    XCTAssertEqual(try XCTUnwrap(page(nil, limit: 3)["runs"] as? [[String: Any]]).count, 3)
    let judged = try XCTUnwrap(page(nil, nodeKey: "judge")["runs"] as? [[String: Any]])
    XCTAssertEqual(Set(judged.compactMap { $0["nodeKey"] as? String }), ["judge"])
    let nodes = try XCTUnwrap(try listed(wc)[id]?["nodes"] as? [String: [String: Any]])
    XCTAssertEqual(
      (nodes["judge"]?["lastRun"] as? [String: Any])?["recordId"] as? Int, ids.first,
      "一覧の lastRun は最新の回")
  }
}
