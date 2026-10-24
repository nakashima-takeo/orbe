import XCTest

@testable import Orbe

/// agent の回の道具——入力をページで読ませ、結果を呼び出しごとにその場で確かめる。1 回の呼び出しは全部受けるか全部断り、
/// 断るときは直すべき件をすべて言う。入力を読み切るまで結果を受けない。何も無い・失敗の申告と結果は混ぜない。
///
/// 壊れると何が起きるか: 外れた件だけが黙って落ち、残りの件で回が通る。agent が直し方を知らずに同じ結果を出し続ける。入力の
/// 一部を読まずに答えた回が通り、読まなかった行が黙って失われる。大きなページが MCP の上限で切られる。結果を出した後の
/// 「何も無い」で結果が消える。判定が知らない候補を対応済みにする。
final class AutomationRunSessionTests: AutomationNodePassTestCase {
  private func rows(_ count: Int, size: Int = 10) -> [AutomationNodeRow] {
    (0..<count).map {
      AutomationNodeRow(
        id: "f:\($0)",
        text: #"{"id":"f:\#($0)","body":""# + String(repeating: "x", count: size) + #""}"#,
        origin: nil, source: nil)
    }
  }

  private func head(_ reply: AutomationRunSession.Reply) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((reply.texts.first ?? "").utf8)))
      as? [String: Any] ?? [:]
  }

  // MARK: - 入力

  /// ページは既定 50 行で、続きの位置（next）を言う。大きさの目安を超えるとそこで止め（先頭の 1 行は必ず返す）、渡した行を
  /// 覚える。
  func testRowsArePagedAndRemembered() {
    let session = AutomationRunSession(
      .process(rows(120), reachesJudge: false), writer: AutomationNodeID(1))

    let first = session.call("read_run_rows", [:])
    XCTAssertEqual(head(first)["count"] as? Int, 50)
    XCTAssertEqual(head(first)["next"] as? Int, 50)
    XCTAssertEqual(head(first)["total"] as? Int, 120)
    XCTAssertEqual(first.texts.last?.split(separator: "\n").count, 50)
    XCTAssertEqual(session.unread.count, 70)

    let last = session.call("read_run_rows", ["offset": 50, "limit": 100])
    XCTAssertNil(head(last)["next"])
    XCTAssertEqual(session.unread, [])

    let big = AutomationRunSession(
      .process(rows(3, size: 30 << 10), reachesJudge: false), writer: AutomationNodeID(1))
    XCTAssertEqual(head(big.call("read_run_rows", ["limit": 3]))["count"] as? Int, 1)
    XCTAssertEqual(head(big.call("read_run_rows", ["offset": 1, "limit": 3]))["count"] as? Int, 1)
  }

  func testPageArgumentsAreChecked() {
    let session = AutomationRunSession(
      .process(rows(3), reachesJudge: false), writer: AutomationNodeID(1))

    XCTAssertTrue(session.call("read_run_rows", ["offset": -1]).isError)
    XCTAssertTrue(session.call("read_run_rows", ["limit": 0]).isError)
    XCTAssertTrue(session.call("read_run_rows", ["limit": 101]).isError)
    XCTAssertTrue(session.call("read_run_rows", ["limit": true]).isError)
    XCTAssertTrue(session.call("put_items", [:]).isError, "役割の道具でない")
  }

  // MARK: - 結果

  /// 入力を読み切るまで結果を受けず、読んでいない位置を言う。
  func testResultsWaitUntilEveryRowIsRead() {
    let session = AutomationRunSession(
      .process(rows(150), reachesJudge: false), writer: AutomationNodeID(1))
    _ = session.call("read_run_rows", ["limit": 10])

    let refused = session.call("put_rows", ["rows": [["id": "f:0"]]])
    XCTAssertTrue(refused.isError)
    XCTAssertTrue(refused.texts[0].contains("offsets 10-149 (140 items)"), refused.texts[0])
    XCTAssertTrue(session.call("report_nothing", ["why": "x"]).isError)
    XCTAssertTrue(session.rejected.isEmpty, "読み残しの断りは外れた件に数えない")
  }

  /// 1 回の呼び出しに外れた件が 1 つでもあれば何も受けず、外れた件をすべて言う。直した呼び出しは受ける。
  func testACallIsAcceptedWhollyOrNotAtAll() {
    let session = AutomationRunSession(
      .process(rows(1), reachesJudge: false), writer: AutomationNodeID(1))
    _ = session.call("read_run_rows", [:])

    let refused = session.call(
      "put_rows", ["rows": [["id": "a"], ["note": "x"], "text", ["id": "a"]]])
    XCTAssertTrue(refused.isError)
    XCTAssertEqual(
      refused.texts[0].split(separator: "\n").dropFirst(),
      ["item 2: missing id", "item 3: not a JSON object", "item 4: id a appeared twice"])
    XCTAssertEqual(session.outputs.count, 0)

    XCTAssertFalse(session.call("put_rows", ["rows": [["id": "a"]]]).isError)
    XCTAssertTrue(session.call("put_rows", ["rows": [["id": "a"]]]).isError, "前の呼び出しとの重なりも")
    XCTAssertTrue(session.call("put_rows", ["rows": []]).isError)
    XCTAssertTrue(session.call("put_rows", ["rows": "a"]).isError)
    XCTAssertEqual(session.outputs.count, 1)
    XCTAssertEqual(
      session.rejected.map(\.line), [2, 3, 4, 1, nil], "空の配列は数えず、配列でない引数は位置の無い 1 件")
  }

  /// 空の配列は断った結果に数えないので、勧めどおり report_nothing を呼べる。report_error を持たない役割には、断られた後の
  /// report_nothing の断りで report_error を勧めない。
  func testAnEmptyCallLeavesRoomToReportNothing() {
    let session = AutomationRunSession(
      .process(rows(1), reachesJudge: false), writer: AutomationNodeID(1))
    _ = session.call("read_run_rows", [:])

    XCTAssertTrue(
      session.call("put_rows", ["rows": []]).texts[0].contains("call report_nothing"))
    XCTAssertFalse(session.call("report_nothing", ["why": "無い"]).isError)

    let refused = AutomationRunSession(
      .process(rows(1), reachesJudge: false), writer: AutomationNodeID(1))
    _ = refused.call("read_run_rows", [:])
    _ = refused.call("put_rows", ["rows": [["note": "x"]]])
    let reply = refused.call("report_nothing", ["why": "無い"])
    XCTAssertTrue(reply.isError)
    XCTAssertFalse(reply.texts[0].contains("report_error"), reply.texts[0])
  }

  /// 何も無いの申告は結果の前だけで、申告の後は結果を受けない。失敗の申告の後も受けない。
  func testNothingAndErrorDoNotMixWithResults() {
    let fetch = AutomationRunSession(.fetch(since: nil), writer: AutomationNodeID(1))
    XCTAssertFalse(fetch.call("report_nothing", ["why": "無い"]).isError)
    XCTAssertTrue(
      fetch.call(
        "put_items",
        [
          "items": [
            ["id": "a", "link": "https://e.com/a", "body": "a", "time": "2026-10-10T09:00:00Z"]
          ]
        ]
      ).isError)
    XCTAssertTrue(fetch.answered)

    let failing = AutomationRunSession(.fetch(since: nil), writer: AutomationNodeID(1))
    XCTAssertFalse(failing.call("report_error", ["what": "落ちた"]).isError)
    XCTAssertEqual(failing.error, "落ちた")
    XCTAssertTrue(failing.call("report_nothing", ["why": "x"]).isError)

    let given = AutomationRunSession(
      .process(rows(1), reachesJudge: false), writer: AutomationNodeID(1))
    _ = given.call("read_run_rows", [:])
    _ = given.call("put_rows", ["rows": [["id": "a"]]])
    XCTAssertTrue(given.call("report_nothing", ["why": "x"]).isError, "結果を出した後は申告しない")
  }

  // MARK: - 判定

  /// 判定は判断待ちの候補と付け先を道具で読み、案は新しい行の id を、対応済みは判断待ちのリンクを指す。id の無い案は
  /// 「id が無い」と言う。
  func testJudgeReadsItsChoicesAndChecksItsDecisions() throws {
    let waiting = AutomationProposal(
      id: 1, runId: 1, judge: AutomationNodeID(2), defId: AutomationNodeDefID(2),
      originNodeId: AutomationNodeID(1), origin: .version(1), item: item("old"), title: "前の提案",
      due: nil, workspace: nil, reason: nil, proposedAt: now, state: .open)
    let session = AutomationRunSession(
      .judge(
        [AutomationSourcedRow(id: "f:a", text: #"{"id":"f:a"}"#, origin: origin("a"))],
        choices: AutomationJudgeChoices(
          open: [waiting],
          workspaces: AutomationWorkspaces(
            listed: [AutomationWorkspace(id: 3, persistentId: UUID(), name: "orbe", root: "/src")],
            home: 1))), writer: AutomationNodeID(1))
    _ = session.call("read_run_rows", [:])

    XCTAssertEqual(
      session.call("read_waiting_proposals", [:]).texts,
      [#"{"link":"https://example.com/old","title":"前の提案"}"#])
    XCTAssertEqual(
      session.call("read_workspaces", [:]).texts, [#"{"name":"orbe","root":"/src","workspace":3}"#])
    XCTAssertEqual(
      session.call("propose", ["proposals": [["title": "x"], ["id": "zzz", "title": "y"]]]).texts[0]
        .split(separator: "\n").dropFirst(),
      ["item 1: missing id", "item 2: propose zzz: not a new item"], "id の無い件もほかの件と一緒に全件言う")
    XCTAssertFalse(
      session.call("propose", ["proposals": [["id": "f:a", "title": "a に返信する", "workspace": 3]]])
        .isError)
    XCTAssertTrue(session.call("resolve", ["links": ["https://example.com/other"]]).isError)
    XCTAssertFalse(session.call("resolve", ["links": ["https://example.com/old"]]).isError)

    guard case .judge(let proposals, let resolved) = session.outputs.output(nothing: nil) else {
      return XCTFail("判定の結果")
    }
    XCTAssertEqual(proposals.map(\.title), ["a に返信する"])
    XCTAssertEqual(resolved, ["https://example.com/old"])
  }
}
