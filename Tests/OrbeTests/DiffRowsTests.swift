import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の並びの純関数——インライン（削除行は古い側の行を指す差し込み・追加は型・文脈は旧番号）と並列（区間の削除と追加を
/// 同じ行から並べ、短い側に詰め物）。壊れると、削除行が別の行に出る・旧番号がずれる・最後の空の行に番号が付く・並列の
/// 両側が揃わず見比べられない。
@MainActor
final class DiffRowsTests: OrbeTestCase {
  private func hunks(_ old: String, _ new: String) -> [LineHunk] {
    LineDiff.hunks(base: old, current: TextRope(new))
  }

  private func lines(_ texts: [String]) -> String { texts.map { $0 + "\n" }.joined() }

  /// 見本（orbe_design の `data.ts` の `diffLines`）と同じ形——同じ 2 行・削除 2 行と追加 8 行の区間・同じ 1 行・追加
  /// 1 行・同じ 1 行。
  private var sample: (old: String, new: String) {
    let old = lines(["a", "", "del 0", "del 1", "ctx", "end"])
    let new = lines(["a", ""] + (0..<8).map { "add \($0)" } + ["ctx", "}", "end"])
    return (old, new)
  }

  /// インラインの差し込みは区間の新しい側の始まりの境に置き、古い側の行を指す。追加の区間は型「追加」でもう一方の番号なし、
  /// 文脈の区間は旧番号。最後の空の行（改行で終わる本文）は両側で揃う。
  func testInlinePlacesRemovedLinesAsInsertionsPointingAtTheOldSide() {
    let (old, new) = sample
    let rows = DiffRows.inline(
      hunks(old, new), old: DiffRows.Side(TextRope(old)), new: DiffRows.Side(TextRope(new)))
    XCTAssertEqual(
      rows.insertions,
      [
        RowInsertion(
          line: 2,
          content: .lines([
            InsertedLine(line: 2, style: DiffStyle.removed),
            InsertedLine(line: 3, style: DiffStyle.removed),
          ]))
      ])
    XCTAssertEqual(
      rows.spans,
      [
        LineSpan(line: 0, otherNumber: 1), LineSpan(line: 2, style: DiffStyle.added),
        LineSpan(line: 10, otherNumber: 5), LineSpan(line: 11, style: DiffStyle.added),
        LineSpan(line: 12, otherNumber: 6),
      ])
  }

  /// 片側だけ（未追跡・追加）なら全部の行が追加で、古い側の番号は無い（最後の空の行にも付かない）。削除なら全部の行が
  /// 古い側の行を指す差し込みで、新しい側は 0 行。
  func testOneSidedDiffsAreWhollyAddedOrRemoved() {
    let text = TextRope(lines(["one", "two"]))
    let added = DiffRows.inline(
      DiffRows.wholeHunks(old: .absent, new: DiffRows.Side(text)), old: .absent,
      new: DiffRows.Side(text))
    XCTAssertEqual(added.insertions, [])
    XCTAssertEqual(
      added.spans, [LineSpan(line: 0, style: DiffStyle.added), LineSpan(line: 2, otherNumber: nil)])
    let removed = DiffRows.inline(
      DiffRows.wholeHunks(old: DiffRows.Side(text), new: .absent), old: DiffRows.Side(text),
      new: .absent)
    XCTAssertEqual(
      removed.insertions,
      [
        RowInsertion(
          line: 0,
          content: .lines([
            InsertedLine(line: 0, style: DiffStyle.removed),
            InsertedLine(line: 1, style: DiffStyle.removed),
          ]))
      ])
    XCTAssertEqual(removed.spans, [])
    XCTAssertEqual(DiffRows.wholeHunks(old: .absent, new: .absent), [])
  }

  /// 末尾の改行が片側にだけあれば、新しい側にだけある最後の空の行は旧番号を持たない。
  func testATrailingRowOnlyOnTheNewSideHasNoOldNumber() {
    let (old, new) = ("a\nb", "a\nb\nc\n")
    let rows = DiffRows.inline(
      hunks(old, new), old: DiffRows.Side(TextRope(old)), new: DiffRows.Side(TextRope(new)))
    XCTAssertEqual(rows.spans.last, LineSpan(line: 3, otherNumber: nil), "\(rows.spans)")
  }

  /// 並列は変わった区間の削除と追加を上から同じ行（同じ y）に並べ、行の数の差の分だけ短い側の区間の後に詰め物が入り、
  /// 続く同じ行も左右で同じ y に来る（見本の `diffLeft` / `diffRight` と VS Code の並列）。
  func testSideBySideBlocksLineUpRowByRow() throws {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
    let (old, new) = sample
    let rows = DiffRows.side(
      hunks(old, new), old: DiffRows.Side(TextRope(old)), new: DiffRows.Side(TextRope(new)))
    let left = try surface(old, rows.left)
    let right = try surface(new, rows.right)
    let pairs = [(0, 0), (1, 1), (2, 2), (3, 3), (4, 10), (5, 12), (6, 13)]
    for (o, n) in pairs {
      XCTAssertEqual(left.rows.y(ofLine: o), right.rows.y(ofLine: n), "行 \(o)/\(n) は同じ y")
    }
    XCTAssertEqual(left.rows.style(ofLine: 2), DiffStyle.removed)
    XCTAssertNil(left.rows.style(ofLine: 4), "区間の後は型なし")
    XCTAssertEqual(right.rows.style(ofLine: 2), DiffStyle.added)
    XCTAssertEqual(right.rows.style(ofLine: 11), DiffStyle.added)
    XCTAssertNil(right.rows.style(ofLine: 12))
    let lineHeight = Double(left.config.lineHeight)
    XCTAssertEqual(left.rows.y(ofLine: 4), 10 * lineHeight, "左は削除 2 行の後に詰め物 6 行（見本と同じ）")
    XCTAssertEqual(left.rows.y(ofLine: 5), 12 * lineHeight, "追加 1 行の向かいに詰め物 1 行")
  }

  private func surface(_ text: String, _ rows: SurfaceRows) throws -> MetalTextSurface {
    let surface = MetalTextSurface(style: EditorStyle.make(), omittedLabel: { "+\($0)" })
    let url = try caseFile("\(UUID().uuidString).txt", text)
    let document = EditorDocument(
      url: url, contents: try EditorDocument.read(url), surface: surface,
      registry: LanguageRegistry(
        queriesRoot: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()))
    addTeardownBlock { _ = document }
    surface.setPresentation(DiffStyle.side)
    surface.setRows(rows)
    return surface
  }
}
