import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の並びの純関数——インライン（削除行は古い側の行を指す差し込み・追加は型・文脈は旧番号）と並列（区間の削除と追加を
/// 同じ行から並べ、短い側に詰め物）。壊れると、削除行が別の行に出る・旧番号がずれる・並列の両側が揃わず見比べられない・新しいファイル
/// や消したファイルに存在しない空の行が出る。
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
    let rows = DiffRows.inline(hunks(old, new), new: DiffRows.Side(TextRope(new)))
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

  /// 片側だけ（新しいファイル・消したファイル）は、版が無い側を 0 行として、有る側の全部の行（改行で終わる本文の末尾の空の
  /// 行も）が追加か削除になる。並列の無い側は詰め物だけ。空の本文の新しいファイルは空の行 1 つの追加で、両側に版があれば
  /// 空の本文どうしは変化が無い。
  func testOneSidedDiffsAddOrRemoveEveryLineOfTheSideThatExists() {
    let limit = EditorDiff.hunkLimit
    let text = TextRope(lines(["one", "two"]))
    let added = DiffRows.inline(
      DiffRows.hunks(old: nil, new: text, limit: limit), new: DiffRows.Side(text))
    XCTAssertEqual(added.insertions, [])
    XCTAssertEqual(added.spans, [LineSpan(line: 0, style: DiffStyle.added)])
    let removed = DiffRows.inline(
      DiffRows.hunks(old: text, new: nil, limit: limit), new: DiffRows.Side(nil))
    XCTAssertEqual(
      removed.insertions,
      [
        RowInsertion(
          line: 0,
          content: .lines((0..<3).map { InsertedLine(line: $0, style: DiffStyle.removed) }))
      ])
    XCTAssertEqual(removed.spans, [])
    let side = DiffRows.side(
      DiffRows.hunks(old: nil, new: text, limit: limit), old: DiffRows.Side(nil),
      new: DiffRows.Side(text))
    XCTAssertEqual(
      side.left.insertions,
      [
        RowInsertion(
          line: 0, content: .lines(Array(repeating: InsertedLine(style: DiffStyle.pad), count: 3)))
      ])
    XCTAssertEqual(side.left.spans, [])
    XCTAssertEqual(side.right.spans, [LineSpan(line: 0, style: DiffStyle.added)])
    XCTAssertEqual(
      DiffRows.hunks(old: nil, new: TextRope(), limit: limit),
      [LineHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1)])
    XCTAssertEqual(DiffRows.hunks(old: TextRope(), new: TextRope(), limit: limit), [])
  }

  /// 末尾の改行を足すのは空の行の追加——足した行だけが追加で、元の最後の行は文脈のまま。
  func testAddingATrailingNewlineAddsTheEmptyRow() {
    let (old, new) = ("a\nb", "a\nb\nc\n")
    let rows = DiffRows.inline(hunks(old, new), new: DiffRows.Side(TextRope(new)))
    XCTAssertEqual(
      rows.spans, [LineSpan(line: 0, otherNumber: 1), LineSpan(line: 2, style: DiffStyle.added)])
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

  /// インラインの見えている先頭から古い側の行を写す——差し込み（削除行）の中の段はその削除行、追加の区間の中は区間の後の
  /// 古い側の行、文脈はずれた分。壊れると、見えている削除行の色が後回しになる。
  func testTheOldLinesInViewFollowTheTopOfTheInlineRows() {
    let (old, new) = sample
    let sample = hunks(old, new)
    let cases: [String: (RowPosition, Int)] = [
      "区間の前": (RowPosition(line: 0), 0),
      "削除行の頭": (RowPosition(line: 2, offset: -2), 2),
      "削除行の 2 段目": (RowPosition(line: 2, offset: -1), 3),
      "差し込みの上は頭で止まる": (RowPosition(line: 2, offset: -9), 2),
      "追加の区間の中は区間の後の行": (RowPosition(line: 5), 4),
      "文脈": (RowPosition(line: 10), 4),
      "追加だけの区間": (RowPosition(line: 11), 5),
      "末尾の文脈": (RowPosition(line: 12), 5),
    ]
    for (message, (top, first)) in cases {
      XCTAssertEqual(DiffRows.oldLines(from: top, count: 3, sample), first...(first + 3), message)
    }
    let removed = DiffRows.hunks(
      old: TextRope(lines((0..<199).map(String.init))), new: nil, limit: EditorDiff.hunkLimit)
    XCTAssertEqual(
      DiffRows.oldLines(from: RowPosition(line: 0, offset: -100), count: 40, removed), 100...140,
      "消したファイルの途中は、見えている削除行から")
    XCTAssertEqual(DiffRows.oldLines(from: .head(of: 0), count: 40, removed), 0...40, "消したファイルの頭")
  }

  /// 古い側が変わらず新しい側が変わる作り直しで、見えている位置は同じ古い側の行（同じ段）へ引き継ぐ——インラインの
  /// 削除行・追加の行・文脈、並列の右の詰め物と古い側より長い追加の段。読んでいた追加の行が新しい並びに無ければ、同じ区間の
  /// 頭。壊れると、index が変わるたびに読んでいた所から跳ぶ。
  func testAPositionIsCarriedAcrossANewSideThroughTheOldSide() {
    let (old, new) = sample
    let before = hunks(old, new)
    let after = hunks(old, lines(["x", "y", "z"]) + new)
    let carry = { (top: RowPosition, from: [LineHunk], to: [LineHunk], side: Bool) in
      DiffRows.position(of: DiffRows.anchor(at: top, from, side: side), to, side: side)
    }
    let inline: [RowPosition: RowPosition] = [
      RowPosition(line: 2, offset: -1): RowPosition(line: 5, offset: -1),
      RowPosition(line: 5): RowPosition(line: 8),
      RowPosition(line: 10): RowPosition(line: 13),
      RowPosition(line: 12): RowPosition(line: 15),
    ]
    for (top, moved) in inline {
      XCTAssertEqual(carry(top, before, before, false), top, "同じ並びなら同じ位置: \(top)")
      XCTAssertEqual(carry(top, before, after, false), moved, "上に 3 行: \(top)")
    }
    let shorterOld = lines(["a", "b", "c", "d", "e", "f"])
    let shorter = hunks(shorterOld, lines(["a", "B", "f"]))
    let shorterAfter = hunks(shorterOld, lines(["x", "y", "z", "a", "B", "f"]))
    let side: [RowPosition: RowPosition] = [
      RowPosition(line: 1): RowPosition(line: 4),
      RowPosition(line: 2, offset: -2): RowPosition(line: 5, offset: -2),
      RowPosition(line: 2, offset: -1): RowPosition(line: 5, offset: -1),
    ]
    for (top, moved) in side {
      XCTAssertEqual(carry(top, shorter, shorter, true), top, "並列で同じ並びなら同じ位置: \(top)")
      XCTAssertEqual(carry(top, shorter, shorterAfter, true), moved, "並列で上に 3 行: \(top)")
    }
    XCTAssertEqual(
      carry(RowPosition(line: 5), before, after, true), RowPosition(line: 8), "並列で古い側より長い追加の段")
    let fewer = hunks(old, lines(["a", "", "add 0", "add 1", "ctx", "}", "end"]))
    XCTAssertEqual(
      carry(RowPosition(line: 3), before, fewer, false), RowPosition(line: 2), "無くなった追加の行は同じ区間の頭")
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
