import XCTest

@testable import OrbeEditorCore

/// 行差分——追加・削除・変更の区間が `@@ -a,b +c,d @@` の形で出る。壊れると git ガター（u5）が
/// 違う行に印を付ける。
final class LineDiffTests: XCTestCase {
  private func hunk(_ oldStart: Int, _ oldCount: Int, _ newStart: Int, _ newCount: Int) -> LineHunk
  {
    LineHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount)
  }

  func testIdenticalTextsHaveNoHunks() {
    XCTAssertEqual(LineDiff.hunks(base: "a\nb\n", current: "a\nb\n"), [])
    XCTAssertEqual(LineDiff.hunks(base: "", current: ""), [])
  }

  func testInsertionDeletionAndModification() {
    XCTAssertEqual(
      LineDiff.hunks(base: "a\nb\nc\n", current: "a\nb\nx\ny\nc\n"), [hunk(2, 0, 3, 2)],
      "追加は old 側が 0 件で直前の行を指す")
    XCTAssertEqual(
      LineDiff.hunks(base: "a\nb\nc\n", current: "a\nc\n"), [hunk(2, 1, 1, 0)],
      "削除は new 側が 0 件で直前の行を指す")
    XCTAssertEqual(
      LineDiff.hunks(base: "a\nb\nc\n", current: "a\nB\nc\n"), [hunk(2, 1, 2, 1)], "変更は両側 1 件")
    XCTAssertEqual(
      LineDiff.hunks(base: "a\n", current: "x\na\n"), [hunk(0, 0, 1, 1)], "先頭への追加は 0 行目の後")
    XCTAssertEqual(LineDiff.hunks(base: "x\na\n", current: "a\n"), [hunk(1, 1, 0, 0)])
  }

  func testAdjacentChangesMergeIntoOneHunkAndDistantOnesStaySeparate() {
    XCTAssertEqual(
      LineDiff.hunks(base: "a\nb\nc\nd\n", current: "a\nB\nC\nX\nd\n"), [hunk(2, 2, 2, 3)],
      "隣り合う削除と追加は 1 つの変更区間")
    XCTAssertEqual(
      LineDiff.hunks(base: "a\nb\nc\nd\ne\n", current: "A\nb\nc\nd\nE\n"),
      [hunk(1, 1, 1, 1), hunk(5, 1, 5, 1)], "離れた変更は別の区間")
  }

  func testTrailingNewlineAndCarriageReturnCount() {
    XCTAssertEqual(
      LineDiff.hunks(base: "a\nb\n", current: "a\nb"), [hunk(2, 1, 2, 1)], "末尾の改行の有無は最後の行の違い")
    XCTAssertEqual(LineDiff.hunks(base: "a\r\nb\r\n", current: "a\r\nb\r\n"), [], "CRLF はそのまま比べる")
    XCTAssertEqual(
      LineDiff.hunks(base: "a\r\nb\r\n", current: "a\nb\n"), [hunk(1, 2, 1, 2)],
      "CRLF と LF は違う行（正規化しない）")
  }

  /// 共通部分を落とした残りが上限を超えると、残り全体を 1 つの変更区間にする（二乗の時間を避ける）。
  /// 残りの中に離れた 2 箇所の変更を置く——Myers なら 2 区間、畳めば 1 区間に割れるので、上限の値・
  /// `<=` の境界・畳む分岐の 3 つがどれも守られる。
  func testLargeReplacementCollapsesButAtTheLimitStillDiffs() {
    let n = LineDiff.maximumComparedLines
    func text(_ count: Int, changingEnds: Bool) -> String {
      let lines = (0..<count).map { i -> String in
        changingEnds && (i == 0 || i == count - 1) ? "new \(i)\n" : "old \(i)\n"
      }
      return "keep\n" + lines.joined() + "tail\n"
    }
    XCTAssertEqual(
      LineDiff.hunks(base: text(n, changingEnds: false), current: text(n, changingEnds: true)),
      [hunk(2, n, 2, n)], "残り 2n 行 > 上限: 1 区間に畳む")
    XCTAssertEqual(
      LineDiff.hunks(
        base: text(n / 2, changingEnds: false), current: text(n / 2, changingEnds: true)),
      [hunk(2, 1, 2, 1), hunk(n / 2 + 1, 1, n / 2 + 1, 1)], "残り n 行 = 上限: 差分を取る")
  }

  /// 上限を超える片側だけの変化（大きな貼り付け・index 版が空）でも、件数 0 の側は直前の行を指す。
  func testLargeOneSidedChangesKeepTheZeroCountConvention() {
    let n = LineDiff.maximumComparedLines + 500
    let block = (0..<n).map { "line \($0)\n" }.joined()
    XCTAssertEqual(LineDiff.hunks(base: "keep\n", current: "keep\n" + block), [hunk(1, 0, 2, n)])
    XCTAssertEqual(LineDiff.hunks(base: "keep\n" + block, current: "keep\n"), [hunk(2, n, 1, 0)])
    XCTAssertEqual(LineDiff.hunks(base: "", current: block), [hunk(0, 0, 1, n)])
  }
}
