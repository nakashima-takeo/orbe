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
  func testLargeReplacementCollapsesIntoOneHunk() {
    let n = LineDiff.maximumComparedLines
    let base = "keep\n" + (0..<n).map { "old \($0)\n" }.joined() + "tail\n"
    let current = "keep\n" + (0..<n).map { "new \($0)\n" }.joined() + "tail\n"
    XCTAssertEqual(LineDiff.hunks(base: base, current: current), [hunk(2, n, 2, n)])

    let small = "keep\n" + (0..<(n / 2)).map { "old \($0)\n" }.joined() + "tail\n"
    let smallNew = "keep\n" + (0..<(n / 2)).map { "new \($0)\n" }.joined() + "tail\n"
    XCTAssertEqual(
      LineDiff.hunks(base: small, current: smallNew), [hunk(2, n / 2, 2, n / 2)], "上限内も同じ形")
  }
}
