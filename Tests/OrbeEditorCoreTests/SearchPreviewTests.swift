import Foundation
import XCTest

@testable import OrbeEditorCore

/// 検索結果の 1 行に見せる切り出し——一致の前は先頭の空白を削り、長ければ単語の境で切って `…` を前に付ける。一致と
/// その後ろは前と合わせて 250 字まで。サロゲートの対は割らない。行が長くても一致の周りだけを見る。
///
/// 壊れると何が起きるか。インデントで一致が行の右へ押し出される。長い行の一致で一致の字そのものが消える、見えない。
/// 絵文字の途中で切れて化けた字が出る。
final class SearchPreviewTests: XCTestCase {
  private func preview(_ line: String, _ needle: String) -> SearchPreview {
    let line = line as NSString
    return SearchPreview(line: line, match: line.range(of: needle))
  }

  func testLeadingWhitespaceBeforeTheMatchIsTrimmed() {
    XCTAssertEqual(
      preview(" \t  let x = foo()", "foo"),
      SearchPreview(before: "let x = ", match: "foo", after: "()"))
  }

  func testALongLeadIsCutAtAWordBoundaryWithAnEllipsis() {
    XCTAssertEqual(
      preview("alpha beta gamma delta epsilon zeta foo", "foo").before, "…gamma delta epsilon zeta "
    )
    XCTAssertEqual(
      preview(String(repeating: "x", count: 40) + "foo", "foo").before,
      "…" + String(repeating: "x", count: 26), "単語の境が無ければ末尾 26 字")
  }

  /// 行の頭がどれだけ長くても一致とその後ろは消えない（前は一致の直前だけを見る）。
  func testTheMatchSurvivesAnArbitrarilyLongLead() {
    let shown = preview(String(repeating: "ab ", count: 5000) + "NEEDLE tail", "NEEDLE")
    XCTAssertEqual(shown.match, "NEEDLE")
    XCTAssertEqual(shown.after, " tail")
    XCTAssertTrue(shown.before.hasPrefix("…"))
    XCTAssertLessThanOrEqual((shown.before as NSString).length, 1 + 200)
  }

  func testTheMatchAndWhatFollowsAreCappedWithTheLeadAt250() {
    let long = preview("foo" + String(repeating: "x", count: 300), "foo")
    XCTAssertEqual(long.match, "foo")
    XCTAssertEqual((long.after as NSString).length, 247)

    let lead = "a " as NSString
    let hugeMatch = String(repeating: "m", count: 300)
    let capped = preview("a " + hugeMatch, hugeMatch)
    XCTAssertEqual((capped.match as NSString).length, 250 - lead.length)
    XCTAssertEqual(capped.after, "")
  }

  func testSurrogatePairsAreNotSplitAtTheCap() {
    let shown = preview("foo" + String(repeating: "x", count: 246) + "😀", "foo")
    XCTAssertEqual(shown.after, String(repeating: "x", count: 246))
  }
}
