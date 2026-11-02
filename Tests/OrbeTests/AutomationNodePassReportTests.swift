import XCTest

@testable import Orbe

/// 報告と仕事の文の残し方——前後の空白を除いて全文を残し、大きさの上限（下流へ渡す行と同じ 64 KiB）を超える文は決まりを外した
/// 出力として断る。agent は道具で出し、出し直せば後の報告で置き換え、空の文は断った結果に数えずに断る（何も無い回は
/// report_nothing）。コマンドの報告は標準出力で、空なら報告なし、上限を超えれば回の失敗。
///
/// 壊れると何が起きるか: 報告の前後の空行が知らせの 1 行目を空にする。空の文が空の報告として残る。長い報告が黙って切られ、
/// 末尾が利用者にも AI にも届かない。上限の無い文が `list_automations` の応答と制御ソケットの 1 行を膨らませる。仕事が
/// 「何もしなかった」を言えない。
final class AutomationNodePassReportTests: AutomationNodePassTestCase {
  /// 上限に収まる長い文。
  private static let long = String(repeating: "あ", count: 2_500)
  /// 64 KiB を超える文（UTF-8 で 3 バイトの字）。
  private static let tooLarge = String(
    repeating: "あ", count: (AutomationOutputs.rowKiB << 10) / 3 + 1)

  /// 空の報告は断った結果に数えずに断り、出し直した報告は前の報告を置き換える（直した中身を受ける）。前後の空白を除き、長くても
  /// 切らない。
  func testReportIsTrimmedReplacedKeptWholeAndAnEmptyTextIsRefused() {
    for _ in 0..<2 {
      start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([row("a")]))
    }

    readAll(0)
    readAll(1)
    XCTAssertTrue(use(0, .putReport, ["text": "  \n"]).isError)
    XCTAssertFalse(use(0, .putReport, ["text": "下書き"]).isError)
    XCTAssertFalse(
      use(0, .putReport, ["text": "\n開いている PR は 2 件。\n- #1 …\n- #2 …\n\n"]).isError,
      "出し直しは受ける")
    use(1, .putReport, ["text": Self.long])
    jobs.finish(0, done())
    jobs.finish(1, done())

    XCTAssertEqual(
      outputs, [.report("開いている PR は 2 件。\n- #1 …\n- #2 …"), .report(Self.long)], "\(outcomes)")
    XCTAssertNil(outcomes.first?.breach)
  }

  /// 上限を超える報告は理由付きで断り、出し直さずに終えた回は出力の形式エラーの失敗。縮めて出し直せば受ける。コマンドの報告は
  /// 標準出力が上限を超えると失敗。
  func testAReportLargerThanTheLimitIsRefused() {
    for _ in 0..<2 {
      start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([row("a")]))
    }
    start(AutomationGraphTests.command("r", from: ["f"], deliver: .report), .report, .report([]))

    readAll(0)
    readAll(1)
    let refused = use(0, .putReport, ["text": Self.tooLarge])
    XCTAssertTrue(refused.isError)
    XCTAssertTrue(refused.texts.joined().contains("larger than 64 KiB"), "\(refused.texts)")
    XCTAssertTrue(use(1, .putReport, ["text": Self.tooLarge]).isError)
    XCTAssertFalse(use(1, .putReport, ["text": Self.long]).isError, "縮めて出し直せば受ける")
    jobs.finish(0, done())
    jobs.finish(1, done())
    jobs.finish(2, printed(Self.tooLarge))

    XCTAssertEqual(
      outcomes.map { if case .failed(.brokeRules, _, _) = $0 { true } else { false } },
      [true, false, true], "\(outcomes)")
    XCTAssertEqual(outputs.compactMap { $0 }, [.report(Self.long)], "\(outcomes)")
  }

  /// 受けた報告の後に文字列でない報告を断られ、直さずに終えた回は出力の形式エラーの失敗。
  func testARefusedReportAfterAnAcceptedOneMustBeFixed() {
    start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([row("a")]))

    readAll(0)
    use(0, .putReport, ["text": "報告"])
    XCTAssertTrue(use(0, .putReport, ["text": 1]).isError)
    jobs.finish(0, done())

    XCTAssertEqual(failed, #"the output of node "r" broke the rules: text has the wrong type"#)
  }

  /// 空の報告を断られた後も、何も無い回として申告できる（中身の無い呼び出しは断った結果に数えない）。
  func testAnEmptyReportStillLeavesRoomToReportNothing() {
    start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([]))

    XCTAssertTrue(use(0, .putReport, ["text": "  \n"]).isError)
    XCTAssertFalse(use(0, .reportNothing, ["why": "動きなし"]).isError)
    jobs.finish(0, done())

    XCTAssertEqual(outputs, [.report(nil)], "\(outcomes)")
  }

  func testNothingToReportLeavesNoText() {
    start(AutomationGraphTests.agent("r", from: ["f"]), .report, .report([]))
    start(AutomationGraphTests.command("r", from: ["f"], deliver: .report), .report, .report([]))

    use(0, .reportNothing, ["why": "動きなし"])
    jobs.finish(0, done())
    jobs.finish(1, printed("  \n"))

    XCTAssertEqual(outputs, [.report(nil), .report(nil)], "\(outcomes)")
  }

  func testWorkReportsWhatItDidOrWhyItDidNothing() {
    for _ in 0..<2 { start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work) }

    use(0, .putReport, ["text": Self.long])
    use(1, .reportNothing, ["why": "対象が無い"])
    jobs.finish(0, done())
    jobs.finish(1, done())

    XCTAssertEqual(
      outputs, [.work(.done(Self.long)), .work(.nothing("対象が無い"))], "\(outcomes)")
  }
}
