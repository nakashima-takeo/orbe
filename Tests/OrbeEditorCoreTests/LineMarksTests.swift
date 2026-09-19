import Foundation
import XCTest

@testable import OrbeEditorCore

/// ハンク → 行の印 → オフセット区間。壊れると git ガターが違う行に出る・削除の三角が違う境に立つ・
/// 打鍵した行の印の区間が古いオフセットのまま残る。
@MainActor
final class LineMarksTests: XCTestCase {
  private func hunk(_ oldStart: Int, _ oldCount: Int, _ newStart: Int, _ newCount: Int) -> LineHunk
  {
    LineHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount)
  }

  /// 追加は old 側 0 件でその新しい行、削除は new 側 0 件でその境、両側にあれば変更——面へ渡る区間で観る
  /// （各行 1 字＋改行の本文なので、n 行目の行頭は 2(n−1)）。
  func testKindsFollowTheHunkShape() {
    let text = (1...8).map { "\($0)\n" }.joined()
    let index = LineIndex(text: text)
    let spans = LineMarks(hunks: [hunk(2, 0, 3, 2), hunk(6, 1, 6, 0), hunk(8, 1, 7, 1)])
      .spans(in: index, length: text.utf16.count)
    XCTAssertEqual(
      spans.marks,
      [
        LineMarkSpans.Mark(range: NSRange(location: 4, length: 4), kind: .added),
        LineMarkSpans.Mark(range: NSRange(location: 12, length: 2), kind: .modified),
      ], "3〜4 行目が追加、7 行目が変更")
    XCTAssertEqual(spans.deletions, [12], "6 行目の下（7 行目の行頭）に削除")
    XCTAssertTrue(LineMarks(hunks: []).spans(in: index, length: text.utf16.count).isEmpty)
  }

  /// 面へ渡す区間は改行込みで、削除の境は次の行の行頭。末尾は本文の長さ（末尾の改行の有無で同じ）。
  func testSpansMapLinesToOffsetsThroughTheLineIndex() {
    let text = "a\nbb\nccc\n"
    let index = LineIndex(text: text)
    let spans = LineMarks(hunks: [hunk(1, 0, 2, 1), hunk(2, 1, 3, 1), hunk(3, 1, 3, 0)])
      .spans(in: index, length: text.utf16.count)
    XCTAssertEqual(
      spans.marks,
      [
        LineMarkSpans.Mark(range: NSRange(location: 2, length: 3), kind: .added),
        LineMarkSpans.Mark(range: NSRange(location: 5, length: 4), kind: .modified),
      ])
    XCTAssertEqual(spans.deletions, [9], "3 行目の下 = 本文の長さ（末尾の空行の行頭）")

    let unterminated = "a\nbb"
    let tail = LineMarks(hunks: [hunk(2, 1, 2, 1), hunk(2, 1, 2, 0)])
      .spans(in: LineIndex(text: unterminated), length: unterminated.utf16.count)
    XCTAssertEqual(tail.marks.map(\.range), [NSRange(location: 2, length: 2)], "最後の行は本文の長さまで")
    XCTAssertEqual(tail.deletions, [4])
    XCTAssertEqual(
      LineMarks(hunks: [hunk(1, 1, 0, 0)]).spans(in: index, length: text.utf16.count).deletions,
      [0],
      "先頭の上は 0")
  }

  /// 文書は baseline を置いた瞬間と編集の後に印を面へ押し、同じ行の中の打鍵でも区間が本文に追従する。
  func testDocumentPushesMarksToTheSurfaceAndKeepsThemInStepWithEdits() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-marks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("a.txt")
    try Data("a\nb\nc\n".utf8).write(to: url)
    let surface = FakeTextSurface(text: "a\nb\nc\n")
    let document = EditorDocument(
      url: url, contents: try EditorDocument.read(url), surface: surface,
      registry: LanguageRegistry(queriesRoot: Queries.root))
    XCTAssertTrue(surface.lineMarks.isEmpty)

    document.baseline = "a\nc\nd\n"
    XCTAssertEqual(
      surface.lineMarks.marks,
      [LineMarkSpans.Mark(range: NSRange(location: 2, length: 2), kind: .added)],
      "baseline を置いた瞬間に押す")
    XCTAssertEqual(surface.lineMarks.deletions, [6], "d の削除は末尾の境")

    surface.replace(NSRange(location: 2, length: 0), with: "xx")
    await Task.yield()
    XCTAssertEqual(
      document.hunks,
      [
        LineHunk(oldStart: 1, oldCount: 0, newStart: 2, newCount: 1),
        LineHunk(oldStart: 3, oldCount: 1, newStart: 3, newCount: 0),
      ], "ハンクは同じ")
    XCTAssertEqual(
      surface.lineMarks.marks.map(\.range), [NSRange(location: 2, length: 4)], "区間は打鍵に追従する")

    document.baseline = nil
    XCTAssertTrue(surface.lineMarks.isEmpty, "baseline が消えれば印も消える")
  }
}
