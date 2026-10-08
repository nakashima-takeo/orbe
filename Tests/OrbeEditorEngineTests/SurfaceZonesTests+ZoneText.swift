import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 区画の文の選択の操作——折り返しをまたぐ選択とコピー・語と伸ばす選択・描き直しをまたぐ選択。壊れると、コメントを
/// コピーすると折り返しの位置に改行が入る、ダブルクリックや ⇧クリックで選べない、スレッドに新しいコメントが届くと
/// 選んでいた範囲が別のコメントへ移る。
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

/// 選べる文のまとまりを 1 行ずつ縦に並べた区画（まとまりの id と文の列。描き直せば列の順に並べ直す）。
@MainActor
private final class CommentsZone: SurfaceZone {
  var comments: [(AnyHashable, String)]

  init(_ comments: [(AnyHashable, String)]) { self.comments = comments }

  func picture(width: CGFloat) -> ZonePicture {
    let elements = comments.enumerated().map { index, comment in
      ZoneElement.selectable(
        ZoneSelectableLine(
          origin: CGPoint(x: 10, y: 20 * CGFloat(index) + 16), text: comment.0,
          range: NSRange(location: 0, length: comment.1.utf16.count),
          styles: ThreadZone.styles(comment.1)))
    }
    return ZonePicture(
      height: 20 * CGFloat(comments.count) + 8, elements: elements,
      texts: comments.map { ZoneText(id: $0.0, string: $0.1) })
  }

  func zone(_ event: ZoneEvent) {}
}
