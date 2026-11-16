import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 絵の差し込みの文の選択の操作——折り返しをまたぐ選択とコピー・語と伸ばす選択・描き直しをまたぐ選択。壊れると、
/// コメントをコピーすると折り返しの位置に改行が入る、ダブルクリックや ⇧クリックで選べない、スレッドに新しいコメントが
/// 届くと選んでいた範囲が別のコメントへ移る。
extension SurfaceZonesTests {
  /// 折り返した行をまたいでドラッグで選べ、⌘C はまとまりの元の文の部分（折り返しの位置に改行は入らない）を写す。
  func testZoneTextSelectionSpansWrappedLinesAndCopiesTheOriginalText() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let comment = String(repeating: "折り返して続くコメントの本文。", count: 8)
    let thread = ThreadZone(comment: comment)
    surface.setRows(zone(thread, at: 4))
    let board = privatePasteboard(opened)
    let lines = try XCTUnwrap(surface.zones[ObjectIdentifier(thread)]?.hits.lines)
    XCTAssertGreaterThan(lines.count, 1, "前提: 本文が折り返している")
    let (first, second) = (lines[0], lines[1])
    let from = first.range.location + 3
    let to = second.range.location + 4
    let point = { (line: ZoneHits.Line, offset: Int) in
      self.viewPoint(surface, thread, CGPoint(x: line.x(of: offset) + 0.5, y: line.origin.y - 3))
    }
    try mouse(opened, .leftMouseDown, at: point(first, from))
    try mouse(opened, .leftMouseDragged, at: point(second, to))
    try mouse(opened, .leftMouseUp, at: point(second, to))
    surface.textView.copy(nil)
    let expected = (comment as NSString).substring(with: NSRange(location: from, length: to - from))
    XCTAssertEqual(board.string(forType: .string), expected)
  }

  /// インラインコード（余白つき）と、置き字・双方向の制御字を含む本文でも、コードの余白の上から始めたドラッグ・コードを
  /// またぐドラッグ・⌘A のどれで選んでも、⌘C が写すのは元の文の部分そのもの（置き字も制御字も足されない）。
  func testCopyingAcrossInlineCodeGivesTheOriginalText() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let parts = [
      "前の文 \u{FFFC} と ", "merges(\u{2067}event)", " の後ろ \u{200F}右から ", "שלום\u{2069}", " で終わる本文。続く文もある。",
    ]
    let comment = parts.joined()
    let styles = parts.enumerated().map { index, part in
      index % 2 == 1
        ? ZoneTextStyle(length: part.utf16.count, font: mono, color: ThreadZone.accent, padding: 4)
        : ZoneTextStyle(length: part.utf16.count, font: ThreadZone.bodyFont, color: ThreadZone.ink)
    }
    let thread = ThreadZone(comment: comment, styles: styles)
    surface.setRows(zone(thread, at: 4))
    let board = privatePasteboard(opened)
    let lines = try XCTUnwrap(surface.zones[ObjectIdentifier(thread)]?.hits.lines)
    let codeStart = parts[0].utf16.count
    let first = try XCTUnwrap(lines.first { NSLocationInRange(codeStart, $0.range) })
    let last = try XCTUnwrap(lines.last)
    let at = { (line: ZoneHits.Line, x: CGFloat) in
      self.viewPoint(surface, thread, CGPoint(x: x, y: line.origin.y - 3))
    }
    try mouse(opened, .leftMouseDown, at: at(first, first.x(of: codeStart) + 1))
    try mouse(opened, .leftMouseDragged, at: at(last, last.x(of: NSMaxRange(last.range) - 2)))
    try mouse(opened, .leftMouseUp, at: at(last, last.x(of: NSMaxRange(last.range) - 2)))
    surface.textView.copy(nil)
    let to = NSMaxRange(last.range) - 2
    XCTAssertEqual(
      board.string(forType: .string),
      (comment as NSString).substring(with: NSRange(location: codeStart, length: to - codeStart)),
      "余白の上から始めたドラッグ")
    surface.textView.selectAll(nil)
    surface.textView.copy(nil)
    XCTAssertEqual(board.string(forType: .string), comment, "⌘A")
  }

  /// ダブルクリックは語を選び、⇧クリックは語の単位のまま選択を伸ばす。
  func testDoubleClickSelectsAWordAndShiftClickExtendsIt() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let thread = ThreadZone(comment: "alpha beta gamma delta")
    surface.setRows(zone(thread, at: 4))
    let board = privatePasteboard(opened)
    let line = try XCTUnwrap(surface.zones[ObjectIdentifier(thread)]?.hits.lines.first)
    let at = { (offset: Int) in
      self.viewPoint(surface, thread, CGPoint(x: line.x(of: offset) + 0.5, y: line.origin.y - 3))
    }
    try mouse(opened, .leftMouseDown, at: at(7), clicks: 2)
    try mouse(opened, .leftMouseUp, at: at(7), clicks: 2)
    surface.textView.copy(nil)
    XCTAssertEqual(board.string(forType: .string), "beta")
    try mouse(opened, .leftMouseDown, at: at(13), flags: .shift)
    try mouse(opened, .leftMouseUp, at: at(13), flags: .shift)
    surface.textView.copy(nil)
    XCTAssertEqual(board.string(forType: .string), "beta gamma")
  }

  /// 描き直しで上に別のまとまりが増えても、選択は同じ id のまとまりの同じ範囲に残る。選んでいた範囲がまとまりの文の外に
  /// なれば、主は本文に戻る。
  func testRedrawingKeepsTheSelectionInTheSameTextById() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let comments = CommentsZone([("b", "second comment text")])
    surface.setRows(zone(comments, at: 4))
    let board = privatePasteboard(opened)
    let line = try XCTUnwrap(surface.zones[ObjectIdentifier(comments)]?.hits.lines.first)
    let at = { (offset: Int) in
      self.viewPoint(
        surface, comments, CGPoint(x: line.x(of: offset) + 0.5, y: line.origin.y - 3))
    }
    try mouse(opened, .leftMouseDown, at: at(7), clicks: 2)
    try mouse(opened, .leftMouseUp, at: at(7), clicks: 2)
    comments.comments.insert(("a", "a new comment arrives above"), at: 0)
    surface.redrawZone(comments)
    XCTAssertEqual(surface.primary, .zoneText)
    surface.textView.copy(nil)
    XCTAssertEqual(board.string(forType: .string), "comment", "同じまとまりの同じ語")
    comments.comments[1].1 = "short"
    surface.redrawZone(comments)
    XCTAssertEqual(surface.primary, .body, "範囲がまとまりの外になれば本文へ")
  }
}

/// 選べる文のまとまりを 1 行ずつ縦に並べた絵の差し込み（まとまりの id と文の列。描き直せば列の順に並べ直す）。
@MainActor
private final class CommentsZone: SurfaceZone {
  var comments: [(AnyHashable, String)]

  init(_ comments: [(AnyHashable, String)]) { self.comments = comments }

  func picture(width: CGFloat) -> ZonePicture {
    ZonePicture(
      height: 20 * CGFloat(comments.count) + 8,
      texts: comments.enumerated().map { index, comment in
        ZoneText(
          id: comment.0, string: comment.1, styles: ThreadZone.styles(comment.1),
          lines: [
            ZoneSelectableLine(
              origin: CGPoint(x: 10, y: 20 * CGFloat(index) + 16),
              range: NSRange(location: 0, length: comment.1.utf16.count))
          ])
      })
  }

  func zone(_ event: ZoneEvent) {}
}
