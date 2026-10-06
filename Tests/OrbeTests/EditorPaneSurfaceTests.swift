import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// pane に載せたテキスト面——ホイールの量と、面が束で渡す編集に検索の一致が付いていくこと。壊れるとホイールで送る量が
/// NSScrollView と違う・字下げや ⌘Z の後に一致の地が本文とずれる。
@MainActor
final class EditorPaneSurfaceTests: OrbeTestCase {
  private var surfaces: EditorSurfaces { EditorSurfaces(queriesRoot: nil) }

  private func lines(_ count: Int) -> String {
    (0..<count).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
  }

  /// マウスのホイールの 1 目盛りで送る量が、NSScrollView の行送りと同じ。NSScrollView はアニメーションで送り、窓を
  /// 画面に出さないテストでは進み方が定まらないので、行送りの値で見る。
  func testWheelNotchMatchesNSScrollView() throws {
    let tab = TerminalTab(cwd: TestScratch.caseDir.path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let document = try tab.editor.open(try caseFile("a.swift", lines(400)), as: .pinned)
    tab.view.editor.layoutSubtreeIfNeeded()
    let surface = try engine(document)
    let lineScroll = NSScrollView().verticalLineScroll
    for notches: Int32 in [1, 3] {
      surface.scroll(toFirstLine: 0)
      let event = try XCTUnwrap(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -notches, wheel2: 0,
          wheel3: 0))
      surface.view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
      XCTAssertEqual(
        surface.scrollPosition.y, Double(lineScroll) * Double(notches), accuracy: 1e-6,
        "\(notches) 目盛り")
    }
  }

  /// 面は 1 回の操作の編集を束で文書へ渡す。検索の一致は、その束（複数行の字下げ）とその undo を編集ごとに畳んで、
  /// 取り直しを待たずに本文の一致の位置に付いていく。壊れると、字下げや ⌘Z の後に一致の地が本文とずれて見える。
  func testSearchMatchesFollowTheBatchesOfTheSurface() throws {
    let tab = TerminalTab(cwd: TestScratch.caseDir.path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let document = try tab.editor.open(try caseFile("a.swift", lines(30)), as: .pinned)
    let pane = tab.view.editor
    pane.layoutSubtreeIfNeeded()
    pane.showSearch()
    pane.search.setNeedle("value")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(pane.search.matches.count, 30, "前提")
    pane.search.refreshDelay.schedule = { _, _ in }
    let responder = document.surface.responder
    responder.selectAll(nil)
    responder.insertTab(nil)
    let text = { document.text.substring(NSRange(location: 0, length: document.text.length)) }
    XCTAssertTrue(text().hasPrefix("    let value0"), "前提: 各行を字下げした")
    XCTAssertEqual(pane.search.matches, occurrences(of: "value", in: text()))
    try XCTUnwrap(responder.undoManager).undo()
    XCTAssertEqual(text(), lines(30), "前提: 戻した")
    XCTAssertEqual(pane.search.matches, occurrences(of: "value", in: text()))
  }

  private func occurrences(of needle: String, in text: String) -> [NSRange] {
    let text = text as NSString
    var found: [NSRange] = []
    var from = 0
    while case let range = text.range(
      of: needle, range: NSRange(location: from, length: text.length - from)),
      range.location != NSNotFound
    {
      found.append(range)
      from = NSMaxRange(range)
    }
    return found
  }
}
