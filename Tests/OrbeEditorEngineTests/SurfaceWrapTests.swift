import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 折り返す面——長い行が本文の区画の幅で段に分かれ、縦の並び・当たり・キャレットの移動が段の単位になる。壊れると、長い
/// 行の右が隠れる、クリックした字と違う所にキャレットが入る、↑↓ が段を飛ばす、段の終わりで打った字が別の段に入る、窓の
/// 幅を変えると読んでいた所が飛ぶ。
@MainActor
final class SurfaceWrapTests: EngineTestCase {
  private let size = CGSize(width: 420, height: 300)

  /// 語が並ぶ長い行と、短い行。
  var sample: String {
    (0..<40).map { "word\($0)" }.joined(separator: " ") + "\nshort\n"
  }

  func opened(_ text: String? = nil) throws -> Opened {
    let opened = try open(text ?? sample, name: "a.txt", size: size)
    _ = host(opened, size: size)
    _ = opened.surface.snapshot()
    return opened
  }

  func wrap(_ opened: Opened, line: Int = 0) throws -> WrappedLine {
    try XCTUnwrap(opened.surface.rows.wrap(ofLine: line), "前提: 行 \(line) は折り返す")
  }

  func testALongLineWrapsWithoutAHorizontalRange() throws {
    let opened = try opened()
    let wrap = try wrap(opened)
    XCTAssertGreaterThanOrEqual(wrap.segments, 3)
    XCTAssertEqual(opened.surface.scrollState().limits.maximum.x, 0, "横の範囲を持たない")
    XCTAssertEqual(
      opened.surface.rows.y(ofLine: 1),
      Double(wrap.segments) * Double(opened.surface.config.lineHeight),
      "次の行は段の数だけ下")
    let text = opened.document.text
    let first = text.substring(NSRange(location: 0, length: wrap.start(of: 1)))
    XCTAssertTrue(first.hasSuffix(" "), "空白の後ろで分ける: \(first)")
  }

  /// 続きの段を押すと、その段の字にキャレットが入る。段の終わりより右を押すと段の終わり（付き）に入り、打った字はそこに入る。
  func testClickingTheSegmentsOfAWrappedLine() throws {
    let opened = try opened()
    let wrap = try wrap(opened)
    try click(opened, row: 1, column: 0)
    XCTAssertEqual(opened.surface.caretLocation, wrap.start(of: 1), "2 段目の頭")
    try click(opened, row: 0, column: 200)
    XCTAssertEqual(opened.surface.caretLocation, wrap.start(of: 1), "1 段目の終わり")
    XCTAssertTrue(opened.surface.editor.state.cursors.primary.upstream)
    type(opened, "Z")
    XCTAssertEqual(
      text(opened.document).utf16.dropFirst(wrap.start(of: 1)).first, "Z".utf16.first,
      "段の終わりで打った字は、その位置に入る")
  }

  /// 段の数が変わらない打鍵でも、段の始まりが動けば、描画スレッドが新しい段の始まりで描く。
  func testTypingThatMovesTheSegmentStartsReachesTheDrawing() throws {
    let opened = try opened()
    let before = try wrap(opened)
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    type(opened, "Z")
    let after = try wrap(opened)
    XCTAssertEqual(after.segments, before.segments, "前提: 段の数は変わらない")
    XCTAssertNotEqual(after.starts, before.starts, "前提: 段の始まりが動く")
    XCTAssertEqual(opened.surface.drawn.rows.wrap(ofLine: 0)?.starts, after.starts)
  }

  /// ↑↓ は段を 1 つずつ動き、⌘→ は段の終わり、⌘← は段の頭へ動く。
  func testKeysMoveBySegments() throws {
    let opened = try opened()
    let wrap = try wrap(opened)
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    let rows = opened.surface.rows
    try key(opened, String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125)
    XCTAssertEqual(rows.segment(containing: opened.surface.caretLocation, line: 0), 1, "↓ は 1 段")
    try key(opened, String(UnicodeScalar(NSUpArrowFunctionKey)!), keyCode: 126)
    XCTAssertEqual(opened.surface.caretLocation, 2, "↑ で戻る")
    try key(opened, String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command], keyCode: 124)
    XCTAssertEqual(opened.surface.caretLocation, wrap.start(of: 1), "⌘→ は段の終わり")
    XCTAssertTrue(opened.surface.editor.state.cursors.primary.upstream)
    try key(opened, String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125)
    try key(opened, String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command], keyCode: 123)
    XCTAssertEqual(opened.surface.caretLocation, wrap.start(of: 1), "⌘← は段の頭")
    XCTAssertFalse(opened.surface.editor.state.cursors.primary.upstream)
  }

  /// 窓の幅を変えると、見えていた先頭の段の頭の字が、先頭に見える段に残る。
  func testResizingKeepsTheFirstVisibleCharacter() throws {
    let text = (0..<60).map { line in (0..<30).map { "w\(line)x\($0)" }.joined(separator: " ") }
      .joined(separator: "\n")
    let opened = try opened(text)
    let surface = opened.surface
    surface.scroll(toFirstLine: 37)
    _ = surface.snapshot()
    let top = surface.viewport.top
    let head = surface.rows.wrap(ofLine: top.line)?.start(of: top.offset) ?? 0
    surface.viewStateDidChange(
      size: CGSize(width: 300, height: size.height), scale: 2, visible: false)
    _ = surface.snapshot()
    let now = surface.viewport.top
    XCTAssertEqual(now.line, top.line)
    XCTAssertEqual(
      surface.rows.segment(containing: head, line: now.line), now.offset,
      "読んでいた字の段が先頭に見える")
  }

  /// 折り返す構成と折り返さない構成（diff）を行き来しても、先頭に見えていた段を含む文書の行が、切り替えた後も先頭に見える。
  func testSwitchingThePresentationKeepsTheFirstVisibleLine() throws {
    let text = (0..<60).map { line in (0..<30).map { "w\(line)x\($0)" }.joined(separator: " ") }
      .joined(separator: "\n")
    let opened = try opened(text)
    let surface = opened.surface
    surface.scroll(toFirstLine: 37)
    _ = surface.snapshot()
    let top = surface.viewport.top
    XCTAssertGreaterThan(top.offset, 0, "前提: 続きの段が先頭に見える")
    surface.setPresentation(SurfacePresentation(showsMinimap: false))
    _ = surface.snapshot()
    XCTAssertNil(surface.rows.wraps)
    XCTAssertEqual(surface.viewport.top.line, top.line, "折り返さない面でも同じ行")
    surface.setPresentation(.code)
    _ = surface.snapshot()
    XCTAssertEqual(surface.viewport.top.line, top.line, "折り返す面に戻っても同じ行")
  }

  /// 折り返さない構成（diff）の面と、上限を超える本文は折り返さない。上限をまたげば、その場で切り替わる。
  func testNonWrappingPresentationsAndHugeTexts() throws {
    let opened = try opened()
    opened.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    XCTAssertNil(opened.surface.rows.wraps, "折り返さない構成")
    opened.surface.setPresentation(.code)
    XCTAssertNotNil(opened.surface.rows.wraps)
    let huge = String(repeating: "x ", count: MetalTextSurface.wrapLimit / 2 + 1)
    opened.surface.replaceAll(with: huge)
    XCTAssertNil(opened.surface.rows.wraps, "上限を超えた本文")
    opened.surface.selectedRange = NSRange(location: 0, length: 4)
    opened.surface.editor.perform(.deleteSelection)
    XCTAssertNotNil(opened.surface.rows.wraps, "上限以下に戻れば折り返す")
  }
}
