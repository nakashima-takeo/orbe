import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// pane に載せたテキスト面——開く・切り替える・閉じる、面が自分で描くスクロールバーからのスクロール、⌘F の次と
/// プロジェクト検索の一致の見せ方、ホイールの量と見えている範囲、検索バーの置き場所。壊れると文書が本体に
/// 載らない・俯瞰で動かない・一致が見えない・検索パネルから押した一致が選ばれず中央に来ない・ホイールで送る量が
/// NSScrollView と違う・検索バーがミニマップに重なる。
@MainActor
final class EditorPaneSurfaceTests: OrbeTestCase {
  private var surfaces: EditorSurfaces { EditorSurfaces(queriesRoot: nil) }

  /// 面の見えている範囲を行で（先頭に見えている行と、見えている行の数）。
  private func lines(of document: EditorDocument) -> (first: CGFloat, visible: CGFloat) {
    let viewport = document.surface.viewport
    return (CGFloat(document.text.row(containing: viewport.firstVisible)), viewport.visibleLines)
  }

  private func lines(_ count: Int) -> String {
    (0..<count).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
  }

  func testOpensSwitchesAndClosesDocuments() throws {
    let tab = TerminalTab(cwd: try XCTUnwrap(TestIsolation.caseDir).path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let a = try tab.editor.open(try caseFile("a.swift", lines(400)))
    let b = try tab.editor.open(try caseFile("b.swift", lines(10)))
    tab.editor.activate(a)
    tab.view.editor.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(a.surface.viewport.visibleLines, 0, "焦点の文書の面が本体に載って大きさを持つ")
    tab.editor.close(b)
    XCTAssertEqual(tab.editor.documents.count, 1)
  }

  /// スクロールバーのトラックを押すとその場で本文が動き、⌘F の次は外の一致の行を中央に見せる。
  func testOverviewAndFindScrollTheSurface() throws {
    let tab = TerminalTab(cwd: try XCTUnwrap(TestIsolation.caseDir).path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let document = try tab.editor.open(try caseFile("a.swift", lines(2000)))
    let pane = tab.view.editor
    pane.layoutSubtreeIfNeeded()
    let view = document.surface.view
    XCTAssertEqual(view.frame, pane.bodyRect, "面は本体全体を覆う")
    let track = NSPoint(x: view.bounds.maxX - 7, y: view.bounds.maxY - 20)
    view.mouseDown(with: view.mouseEvent(.leftMouseDown, at: track))
    view.mouseUp(with: view.mouseEvent(.leftMouseUp, at: track))
    XCTAssertGreaterThan(lines(of: document).first, 1_000, "トラックを押した位置へ飛ぶ")

    pane.showSearch()
    pane.search.setNeedle("value1500 ")
    XCTAssertTrue(document.waitUntilCaughtUp())
    pane.search.next()
    let (first, visible) = lines(of: document)
    XCTAssertEqual(first + visible / 2, 1500.5, accuracy: 1, "一致の行を中央に見せる")
    pane.closeSearch()
  }

  /// プロジェクト検索の一致を押すと、文書を開いて一致を選び、その行を中央に見せ、一致の地と現在の一致を面へ押す（面は
  /// 押された地から本文と俯瞰を描く）。
  /// 端末は載せない——shell の cwd の報告が検索の根を動かさない。
  func testProjectSearchOpensAndCentersTheMatch() throws {
    let repo = try TempGitRepo(name: "orbe-metal-search")
    defer { repo.cleanup() }
    let content = lines(2000)
    try repo.write("a.swift", content)
    let tab = TerminalTab(cwd: repo.root, editorSurfaces: surfaces)
    let pane = tab.view.editor
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = pane
    defer { window.contentView = nil }
    pane.layoutSubtreeIfNeeded()
    let search = pane.projectSearch
    pane.showProjectSearch(seed: nil)
    search.setPattern("value1500 ")
    search.search()
    pumpMain(until: { search.phase == .done }, "検索が終わる")

    search.click(ProjectSearch.RowID(path: "a.swift", match: 0))

    let document = try XCTUnwrap(pane.document)
    let match = (content as NSString).range(of: "value1500 ")
    XCTAssertEqual(document.surface.selectedRange, match, "一致を選ぶ")
    let (first, visible) = lines(of: document)
    XCTAssertEqual(first + visible / 2, 1500.5, accuracy: 1, "一致の行を中央に見せる")
    XCTAssertEqual(pane.findGround.matches, [match])
    XCTAssertEqual(pane.findGround.current, [match])
  }

  /// マウスのホイールの 1 目盛りで送る量が、NSScrollView の行送りと同じ。NSScrollView はアニメーションで送り、窓を
  /// 画面に出さないテストでは進み方が定まらないので、行送りの値で見る。
  func testWheelNotchMatchesNSScrollView() throws {
    let tab = TerminalTab(cwd: try XCTUnwrap(TestIsolation.caseDir).path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let document = try tab.editor.open(try caseFile("a.swift", lines(400)))
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

  /// 見えている範囲は、先頭に見えている行（上へ一部が隠れていてもその行）の行頭と、本体の高さから上端の余白を除いた
  /// 高さに入る行の数。
  func testViewportFollowsTheLineHeightAndTheBody() throws {
    let tab = TerminalTab(cwd: try XCTUnwrap(TestIsolation.caseDir).path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let document = try tab.editor.open(try caseFile("a.swift", lines(400)))
    let pane = tab.view.editor
    pane.layoutSubtreeIfNeeded()
    let surface = try engine(document)
    let style = EditorStyle.make()
    for line: CGFloat in [0.5, 137.25] {
      surface.scroll(toFirstLine: line)
      let viewport = document.surface.viewport
      XCTAssertEqual(viewport.firstVisible, document.text.lineStart(Int(line)))
      XCTAssertEqual(
        viewport.visibleLines, (pane.bodyRect.height - style.topInset) / style.lineHeight,
        accuracy: 1e-6)
    }
  }

  /// 検索バーは、面が答える右列の幅から、ミニマップの左 12・本体の上端から 12 に浮く。窓の幅が変われば追従する。
  func testTheFindBarFloatsLeftOfTheSurfacesOwnRightColumn() throws {
    let tab = TerminalTab(cwd: try XCTUnwrap(TestIsolation.caseDir).path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let document = try tab.editor.open(try caseFile("a.swift", lines(2000)))
    let pane = tab.view.editor
    pane.showSearch()
    let surface = document.surface
    for width: CGFloat in [900, 700] {
      window.setContentSize(NSSize(width: width, height: 500))
      pane.layoutSubtreeIfNeeded()
      let bar = try XCTUnwrap(pane.searchBar)
      XCTAssertEqual(
        bar.frame.maxX, pane.bounds.maxX - surface.rightColumnWidth - 12, accuracy: 0.5)
      XCTAssertEqual(bar.frame.minY, pane.bodyRect.minY + 12, accuracy: 0.5)
    }
    pane.closeSearch()
  }

  /// 面は 1 回の操作の編集を束で文書へ渡す。検索の一致は、その束（複数行の字下げ）とその undo を編集ごとに畳んで、
  /// 取り直しを待たずに本文の一致の位置に付いていく。壊れると、字下げや ⌘Z の後に一致の地が本文とずれて見える。
  func testSearchMatchesFollowTheBatchesOfTheSurface() throws {
    let tab = TerminalTab(cwd: try XCTUnwrap(TestIsolation.caseDir).path, editorSurfaces: surfaces)
    let window = hostEditor(tab, width: 900, height: 500)
    defer { window.contentView = nil }
    let document = try tab.editor.open(try caseFile("a.swift", lines(30)))
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
