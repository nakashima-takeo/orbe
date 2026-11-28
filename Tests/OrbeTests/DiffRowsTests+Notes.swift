import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 並びに混ぜる注記（PR のスレッドの絵・印を出せる行・スレッドのある行）。壊れると、古い側の行のスレッドが別の削除行の下に
/// 出る・並列の左右がスレッドの高さだけずれる・コメントできない行に印が出る・スレッドのある行の地が変わらない。
extension DiffRowsTests {
  /// 代表的な差分構成——同じ 2 行・削除 2 行と追加 8 行の区間・同じ 1 行・追加 1 行・同じ 1 行。
  private var noted: Noted {
    let old = ["a", "", "del 0", "del 1", "ctx", "end"].map { $0 + "\n" }.joined()
    let new = (["a", ""] + (0..<8).map { "add \($0)" } + ["ctx", "}", "end"])
      .map { $0 + "\n" }.joined()
    return Noted(
      hunks: LineDiff.hunks(base: old, current: TextRope(new)), old: DiffRows.Side(TextRope(old)),
      new: DiffRows.Side(TextRope(new)))
  }

  /// インライン: 新しい側の行の絵はその行の後（次の区間の削除行より上）、削除行の絵はその削除行の直後で塊を割り、文脈の行
  /// の古い側の絵は対応する新しい側の行の後。スレッドのある行は地の型が変わり、記号の型は元のまま。
  func testInlineNotesPlaceZonesUnderTheirRowsAndSplitTheRemovedBlock() {
    let (hunks, new) = (noted.hunks, noted.new)
    let (above, removed, context) = (StubZone(), StubZone(), StubZone())
    var notes = DiffRows.Notes()
    notes.zones = [
      DiffRows.Zone(version: .new, line: 1, zone: above),
      DiffRows.Zone(version: .old, line: 2, zone: removed),
      DiffRows.Zone(version: .old, line: 4, zone: context),
    ]
    notes.overrides = [
      .init(range: .at(.old, 2), kind: .thread), .init(range: .at(.old, 4), kind: .thread),
      .init(range: .at(.new, 1), kind: .thread),
    ]
    let rows = DiffRows.inline(hunks, new: new, notes: notes)
    XCTAssertEqual(
      rows.insertions,
      [
        RowInsertion(line: 2, content: .zone(above)),
        RowInsertion(
          line: 2,
          content: .lines([
            InsertedLine(line: 2, style: DiffStyle.removed, override: DiffStyle.threadOverride)
          ])),
        RowInsertion(line: 2, content: .zone(removed)),
        RowInsertion(line: 2, content: .lines([InsertedLine(line: 3, style: DiffStyle.removed)])),
        RowInsertion(line: 11, content: .zone(context)),
      ])
    XCTAssertEqual(rows.spans.first { $0.line == 1 }?.override, DiffStyle.threadOverride)
    XCTAssertEqual(
      rows.spans.first { $0.line == 10 }?.override, DiffStyle.threadOverride,
      "古い側の文脈の行 4 は新しい側の行 10")
    XCTAssertEqual(rows.spans.first { $0.line == 10 }?.otherNumber, 5, "割っても旧番号は続く")
  }

  /// 並列: 古い側の行の絵は左、新しい側の行の絵は右の行の後に置き、反対側の同じ段の後に相手と同じ高さの空きを置く。短い側の
  /// 段は区間の後ろの詰め物の塊の途中になる。同じ段の左右の絵は、両側で同じ順に並ぶ。
  func testSideNotesPutGapsAtTheSameRowOnTheOtherSide() {
    let (hunks, old, new) = (noted.hunks, noted.old, noted.new)
    let (left, right, padded) = (StubZone(), StubZone(), StubZone())
    var notes = DiffRows.Notes()
    notes.zones = [
      DiffRows.Zone(version: .old, line: 2, zone: left),
      DiffRows.Zone(version: .new, line: 2, zone: right),
      DiffRows.Zone(version: .new, line: 5, zone: padded),
    ]
    let rows = DiffRows.side(hunks, old: old, new: new, notes: notes)
    let pad = InsertedLine(style: DiffStyle.pad)
    XCTAssertEqual(
      rows.left.insertions,
      [
        RowInsertion(line: 3, content: .zone(left)),
        RowInsertion(line: 3, content: .gap(right)),
        RowInsertion(line: 4, content: .lines([pad, pad])),
        RowInsertion(line: 4, content: .gap(padded)),
        RowInsertion(line: 4, content: .lines([pad, pad, pad, pad])),
        RowInsertion(line: 5, content: .lines([pad])),
      ])
    XCTAssertEqual(
      rows.right.insertions,
      [
        RowInsertion(line: 3, content: .gap(left)),
        RowInsertion(line: 3, content: .zone(right)),
        RowInsertion(line: 6, content: .zone(padded)),
      ])
  }

  /// 印の組はコメントできる行のまとまりの行（とその中の削除行）にだけ付き、まとまりの端で文書の行の区間が割れる。注記が
  /// 無ければ、並びは注記の無い並びと同じ。
  func testCommentableRangesSplitSpansAndMarkRemovedLines() {
    let (hunks, new) = (noted.hunks, noted.new)
    let plain = DiffRows.inline(hunks, new: new)
    let empty = DiffRows.inline(hunks, new: new, notes: DiffRows.Notes())
    XCTAssertEqual(empty.insertions, plain.insertions)
    XCTAssertEqual(empty.spans, plain.spans)
    var notes = DiffRows.Notes()
    notes.hunks = DiffRows.CommentHunks(items: [.init(old: 3..<5, new: 0..<4)])
    let rows = DiffRows.inline(hunks, new: new, notes: notes)
    XCTAssertEqual(
      rows.spans,
      [
        LineSpan(line: 0, otherNumber: 1, markGroup: 0),
        LineSpan(line: 2, style: DiffStyle.added, markGroup: 0),
        LineSpan(line: 4, style: DiffStyle.added), LineSpan(line: 10, otherNumber: 5),
        LineSpan(line: 11, style: DiffStyle.added), LineSpan(line: 12, otherNumber: 6),
      ])
    XCTAssertEqual(
      rows.insertions,
      [
        RowInsertion(
          line: 2,
          content: .lines([
            InsertedLine(line: 2, style: DiffStyle.removed),
            InsertedLine(line: 3, style: DiffStyle.removed, markGroup: 0),
          ]))
      ])
  }

  /// 範囲が覆う行は次のとおり。側をまたぐ範囲は、削除行から追加の行へも、文脈の行から後ろの削除行へも、インラインの並びの順で
  /// 間に出る行を覆う（削除行の後に追加の行）。同じ側の範囲は、その側の始まり〜終わりだけ。インラインで地を替える行は、同じ側の
  /// 範囲でも、間に差し込まれた削除行を含む。
  func testRangesCoverTheRowsBetweenTheirEnds() {
    let hunks = noted.hunks
    let across = DiffLineRange(
      start: DiffLine(version: .old, line: 3), end: DiffLine(version: .new, line: 4))
    XCTAssertTrue(DiffRows.coveredLines(of: across, hunks) == (3..<4, 2..<5))
    let backward = DiffLineRange(
      start: DiffLine(version: .new, line: 1), end: DiffLine(version: .old, line: 3))
    XCTAssertTrue(
      DiffRows.coveredLines(of: backward, hunks) == (1..<4, 1..<2),
      "文脈の行から後ろの削除行まで——文脈の行は古い側の番号も持つ")
    let same = DiffLineRange(
      start: DiffLine(version: .new, line: 1), end: DiffLine(version: .new, line: 10))
    XCTAssertTrue(DiffRows.coveredLines(of: same, hunks) == (0..<0, 1..<11))
    XCTAssertTrue(DiffRows.inlineLines(of: same, hunks) == (1..<5, 1..<11))
    var notes = DiffRows.Notes()
    notes.overrides = [.init(range: same, kind: .draft)]
    let rows = DiffRows.inline(hunks, new: noted.new, notes: notes)
    guard case .lines(let removed) = rows.insertions.first?.content else {
      return XCTFail("前提: 削除行の塊")
    }
    XCTAssertEqual(removed.map(\.override), [DiffStyle.draftOverride, DiffStyle.draftOverride])
    XCTAssertEqual(rows.spans.first { $0.line == 1 }?.override, DiffStyle.draftOverride)
    XCTAssertNil(rows.spans.first { $0.line == 11 }?.override)
  }
}

/// 注記の場の行差分と両側の大きさ。
private struct Noted {
  let hunks: [LineHunk]
  let old: DiffRows.Side
  let new: DiffRows.Side
}

/// 並びに置くだけの絵の差し込み（絵を描かない）。
@MainActor
private final class StubZone: SurfaceZone {
  func picture(width: CGFloat) -> ZonePicture { ZonePicture(height: 10) }
  func zone(_ event: ZoneEvent) {}
}
