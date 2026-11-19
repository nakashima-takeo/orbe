import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 並びに混ぜる注記（PR のスレッドの絵・印を出せる行・スレッドのある行）。壊れると、古い側の行のスレッドが別の削除行の下に
/// 出る・並列の左右がスレッドの高さだけずれる・コメントできない行に印が出る・スレッドのある行の地が変わらない。
extension DiffRowsTests {
  /// 見本と同じ形——同じ 2 行・削除 2 行と追加 8 行の区間・同じ 1 行・追加 1 行・同じ 1 行。
  private var noted: (hunks: [LineHunk], old: DiffRows.Side, new: DiffRows.Side) {
    let old = ["a", "", "del 0", "del 1", "ctx", "end"].map { $0 + "\n" }.joined()
    let new = (["a", ""] + (0..<8).map { "add \($0)" } + ["ctx", "}", "end"])
      .map { $0 + "\n" }.joined()
    return (
      LineDiff.hunks(base: old, current: TextRope(new)), DiffRows.Side(TextRope(old)),
      DiffRows.Side(TextRope(new))
    )
  }

  /// インライン: 新しい側の行の絵はその行の後（次の区間の削除行より上）、削除行の絵はその削除行の直後で塊を割り、文脈の行
  /// の古い側の絵は対応する新しい側の行の後。スレッドのある行は地の型が変わり、記号の型は元のまま。
  func testInlineNotesPlaceZonesUnderTheirRowsAndSplitTheRemovedBlock() {
    let (hunks, _, new) = noted
    let (above, removed, context) = (StubZone(), StubZone(), StubZone())
    var notes = DiffRows.Notes()
    notes.zones = [
      DiffRows.Zone(version: .new, line: 1, zone: above),
      DiffRows.Zone(version: .old, line: 2, zone: removed),
      DiffRows.Zone(version: .old, line: 4, zone: context),
    ]
    notes.threads = ([2, 4], [1])
    let rows = DiffRows.inline(hunks, new: new, notes: notes)
    XCTAssertEqual(
      rows.insertions,
      [
        RowInsertion(line: 2, content: .zone(above)),
        RowInsertion(
          line: 2, content: .lines([InsertedLine(line: 2, style: DiffStyle.removedThread)])),
        RowInsertion(line: 2, content: .zone(removed)),
        RowInsertion(line: 2, content: .lines([InsertedLine(line: 3, style: DiffStyle.removed)])),
        RowInsertion(line: 11, content: .zone(context)),
      ])
    XCTAssertEqual(rows.spans.first { $0.line == 1 }?.style, DiffStyle.contextThread)
    XCTAssertEqual(
      rows.spans.first { $0.line == 10 }?.style, DiffStyle.contextThread,
      "古い側の文脈の行 4 は新しい側の行 10")
    XCTAssertEqual(rows.spans.first { $0.line == 10 }?.otherNumber, 5, "割っても旧番号は続く")
  }

  /// 並列: 古い側の行の絵は左、新しい側の行の絵は右の行の後に置き、反対側の同じ段の後に相手と同じ高さの空きを置く。短い側の
  /// 段は区間の後ろの詰め物の塊の途中になる。同じ段の左右の絵は、両側で同じ順に並ぶ。
  func testSideNotesPutGapsAtTheSameRowOnTheOtherSide() {
    let (hunks, old, new) = noted
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

  /// 印は印を出せる行の区間（とその中の削除行）にだけ付き、区間の端で文書の行の区間が割れる。注記が無ければ、並びは注記の
  /// 無い並びと同じ。
  func testCommentableRangesSplitSpansAndMarkRemovedLines() {
    let (hunks, _, new) = noted
    let plain = DiffRows.inline(hunks, new: new)
    let empty = DiffRows.inline(hunks, new: new, notes: DiffRows.Notes())
    XCTAssertEqual(empty.insertions, plain.insertions)
    XCTAssertEqual(empty.spans, plain.spans)
    var notes = DiffRows.Notes()
    notes.commentable = ([3..<5], [0..<4])
    let rows = DiffRows.inline(hunks, new: new, notes: notes)
    XCTAssertEqual(
      rows.spans,
      [
        LineSpan(line: 0, otherNumber: 1, allowsTrailingMark: true),
        LineSpan(line: 2, style: DiffStyle.added, allowsTrailingMark: true),
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
            InsertedLine(line: 3, style: DiffStyle.removed, allowsTrailingMark: true),
          ]))
      ])
  }
}

/// 並びに置くだけの絵の差し込み（絵を描かない）。
@MainActor
private final class StubZone: SurfaceZone {
  func picture(width: CGFloat) -> ZonePicture { ZonePicture(height: 10) }
  func zone(_ event: ZoneEvent) {}
}
