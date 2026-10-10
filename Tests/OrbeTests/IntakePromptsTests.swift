import XCTest

@testable import Orbe

/// 取得と判定の出力の関門——取得役の `{"error":…}`・全行が形違いは失敗、同じ id の 2 度目は捨てる。判定の行は、今回渡した
/// 新しい項目・出ている提案だけを指し、タイトルと期限がタスクの規則に合うものだけを受ける。依頼文には新しい項目だけが載る。
///
/// 壊れると何が起きるか。取得役が「ツールが使えない」と言った回を 0 件と読み、提案が一斉に下がる。判定が別の受信の項目や
/// 存在しない提案を指しても通り、タスクにできないタイトルの提案が棚に並ぶ。
final class IntakePromptsTests: OrbeTestCase {
  private let line =
    #"{"id":"1","link":"https://example.com/1","body":"本文","time":"2026-10-10T09:00:00Z"}"#

  func testFetchReadsItemsAndDropsRepeatedIds() {
    let text = [line, #"{"id":"2"}"#, line].joined(separator: "\n")

    guard case .items(let items, let rejected) = IntakePrompts.readFetch(text) else {
      return XCTFail("読めるはず")
    }
    XCTAssertEqual(items.map(\.id), ["1"])
    XCTAssertEqual(rejected.count, 2)
    XCTAssertEqual(rejected.reasons, ["line 2: missing link", "id 1 appeared twice"])
  }

  func testEmptyFetchIsZeroItems() {
    XCTAssertEqual(IntakePrompts.readFetch(""), .items([], rejected: IntakeRejections()))
  }

  /// link は http(s)、time は ISO 8601 でなければ形違い。
  func testFetchRejectsNonWebLinksAndBadTimes() {
    let text = [
      #"{"id":"1","link":"file:///etc/passwd","body":"","time":"2026-10-10T09:00:00Z"}"#,
      #"{"id":"2","link":"https://example.com/2","body":"","time":"昨日"}"#, line,
    ].joined(separator: "\n")

    guard case .items(let items, let rejected) = IntakePrompts.readFetch(text) else {
      return XCTFail("読めるはず")
    }
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(rejected.reasons, ["line 1: invalid link", "line 2: invalid time"])
  }

  func testErrorLineFailsTheFetch() {
    let text = line + "\n" + #"{"error":"slack token expired"}"#

    guard case .failed(let reason, _) = IntakePrompts.readFetch(text) else {
      return XCTFail("失敗のはず")
    }
    XCTAssertEqual(reason, "the fetch reported an error: slack token expired")
  }

  func testAllMalformedLinesFailTheFetch() {
    guard case .failed(let reason, let rejected) = IntakePrompts.readFetch("取れませんでした\n{}")
    else { return XCTFail("失敗のはず") }
    XCTAssertEqual(reason, "every line of the fetch output was malformed")
    XCTAssertEqual(rejected.count, 2)
  }

  // MARK: - 判定

  private let items = [IntakeStoreTests.item("a"), IntakeStoreTests.item("b")]
  private var open: [IntakeProposal] {
    [
      IntakeProposal(
        id: 1, intakeId: 1, item: IntakeStoreTests.item("old"), title: "前の提案", due: nil,
        proposedAt: Date(timeIntervalSince1970: 0), state: .open)
    ]
  }

  func testJudgeKeepsOnlyLinesThatPointAtWhatWasGiven() {
    let text = [
      #"{"propose":"a","title":"レビューする","due":"2026-10-12"}"#,
      #"{"propose":"a","title":"もう一度"}"#,
      #"{"propose":"zzz","title":"知らない項目"}"#,
      #"{"propose":"b","title":"二行\nのタイトル"}"#,
      #"{"propose":"b","title":"期限が変","due":"2026-02-30"}"#,
      #"{"resolve":"https://example.com/old"}"#,
      #"{"resolve":"https://example.com/unknown"}"#,
      #"{"propose":"b","resolve":"https://example.com/old","title":"両方"}"#,
      "説明文",
    ].joined(separator: "\n")

    let (decisions, rejected) = IntakePrompts.readJudge(text, items: items, open: open)

    XCTAssertEqual(
      decisions,
      [
        .propose(itemId: "a", title: "レビューする", due: TaskItem.DueDate("2026-10-12")),
        .resolve(link: "https://example.com/old"),
      ])
    XCTAssertEqual(rejected.count, 7)
    XCTAssertEqual(rejected.reasons.count, IntakeRejections.retainedReasons, "理由は最初の数件だけ残す")
  }

  /// 判定の依頼文には、新しい項目・出ている提案・期限を決めるための今日と利用者の指示文が載る。
  func testJudgePromptCarriesTheNewItemsTheOpenProposalsAndToday() throws {
    let prompt = IntakePrompts.judge(
      instruction: "自分がやるべきことだけ", items: [items[0]], open: open,
      now: Date(timeIntervalSince1970: 1_800_000_000),
      timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))

    XCTAssertTrue(prompt.contains("自分がやるべきことだけ"))
    XCTAssertTrue(prompt.contains(#""id":"a""#))
    XCTAssertFalse(prompt.contains(#""id":"b""#), "新しい項目だけを載せる")
    XCTAssertTrue(prompt.contains(#""link":"https://example.com/old","title":"前の提案""#))
    XCTAssertTrue(prompt.contains("2027-01-15 17:00"), prompt)
    XCTAssertTrue(prompt.contains("Asia/Tokyo"))
  }
}
