import Foundation
import OrbeTestSupport
import XCTest

@testable import OrbeEditorCore

/// ハンク → 行の印（文書の行）。壊れると git ガターが違う行に出る・末尾の空の行に印が付かない・削除の三角が違う境に
/// 立つ・打鍵で行がずれても印が古い行に残る。
@MainActor
final class LineMarksTests: XCTestCase {
  private func hunk(_ oldStart: Int, _ oldCount: Int, _ newStart: Int, _ newCount: Int) -> LineHunk
  {
    LineHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount)
  }

  private func bar(_ rows: ClosedRange<Int>, _ kind: LineMarks.Kind) -> LineMarks.Bar {
    LineMarks.Bar(rows: rows, kind: kind)
  }

  /// 追加は old 側 0 件でその新しい行、削除は new 側 0 件でその境、両側にあれば変更。
  func testKindsFollowTheHunkShape() {
    let marks = LineMarks(
      hunks: [hunk(2, 0, 3, 2), hunk(6, 1, 6, 0), hunk(8, 1, 7, 1)], lineCount: 9)
    XCTAssertEqual(marks.bars, [bar(2...3, .added), bar(6...6, .modified)], "3〜4 行目が追加、7 行目が変更")
    XCTAssertEqual(marks.deletions, [6], "6 行目の下（7 行目の上端）に削除")
    XCTAssertTrue(LineMarks(hunks: [], lineCount: 9).isEmpty)
  }

  /// 区間は末尾の空の行まで届き、本文に無い行は落ちる。境は 0（先頭の上）から行数（最後の行の下）まで。
  func testMarksAreRowsOfTheTextIncludingTheTrailingEmptyLine() {
    let marks = LineMarks(hunks: [hunk(1, 0, 2, 2), hunk(2, 1, 3, 0)], lineCount: 3)
    XCTAssertEqual(marks.bars, [bar(1...2, .added)], "`a` → `a\nb\n` の 2 行の追加は末尾の空の行まで")
    XCTAssertEqual(marks.deletions, [3], "最後の行（空の行）の下")

    let outside = LineMarks(
      hunks: [hunk(1, 1, 0, 0), hunk(1, 1, 2, 3), hunk(5, 0, 4, 1), hunk(6, 1, 9, 0)],
      lineCount: 3)
    XCTAssertEqual(outside.bars, [bar(1...2, .modified)], "本文を越える区間は最後の行で切り、本文に無い区間は落とす")
    XCTAssertEqual(outside.deletions, [0, 3], "先頭の上は 0、本文を越える境は最後の行の下")
  }

  /// 文書はハンクが届いたときと編集の後に印を面へ押し、打鍵で行が増減すれば、差分が届く前に印がその場で追従する。
  func testDocumentPushesMarksToTheSurfaceAndKeepsThemInStepWithEdits() throws {
    let dir = TestScratch.caseDir
      .appendingPathComponent("orbe-marks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("a.txt")
    try Data("a\nb\nc\n".utf8).write(to: url)
    let surface = FakeTextSurface(text: "a\nb\nc\n")
    let document = EditorDocument(
      url: url, contents: try EditorDocument.read(url), surface: surface,
      registry: LanguageRegistry(queriesRoot: Queries.root))
    XCTAssertTrue(surface.lineMarks.isEmpty)

    document.baseline = "a\nc\nd\n"
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(surface.lineMarks.bars, [LineMarks.Bar(rows: 1...1, kind: .added)], "ハンクが届けば押す")
    XCTAssertEqual(surface.lineMarks.deletions, [3], "d の削除は末尾の空の行の上")

    surface.replace(NSRange(location: 0, length: 0), with: "z\n")
    XCTAssertEqual(
      surface.lineMarks.bars, [LineMarks.Bar(rows: 2...2, kind: .added)], "印は打鍵の行の増減にその場で追従する")
    XCTAssertEqual(surface.lineMarks.deletions, [4])
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(
      surface.lineMarks.bars,
      [LineMarks.Bar(rows: 0...0, kind: .added), LineMarks.Bar(rows: 2...2, kind: .added)],
      "差分が届けば追いつく")
    XCTAssertEqual(surface.lineMarks.deletions, [4])

    document.baseline = nil
    XCTAssertTrue(surface.lineMarks.isEmpty, "baseline が消えれば印も消える")
  }
}
