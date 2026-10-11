import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe

/// サイドバーの一覧のつまみの決まり——見せる規則（ホバー・ドラッグ・位置の変化と、止まってからの消え始め）と、弾みの間も
/// つまみをトラックの中に置く位置の丸め。エクスプローラーのツリー（SwiftUI）に重ねたつまみの、ホイール・ドラッグ・クリック。
///
/// 壊れると何が起きるか。一覧を出しただけでつまみが点く。ポインタを外へ出しても、少し前の
/// スクロールのせいで見え続ける。スクロールを止めても消えない。弾みの間につまみがトラックの外へはみ出す。ツリーのつまみの
/// 上でホイールが効かない、ドラッグがポインタからずれる・末尾まで届かない、つまみを押すと下の行が開く、帯の右端に
/// かかる行（git バッジの辺り）を押せない。
@MainActor
final class SidebarScrollbarTests: OrbeTestCase {
  private typealias Visibility = SidebarScrollbar.Visibility

  func testFirstPositionDoesNotShowAndAChangeShowsUntilTheDelay() {
    var visibility = Visibility(hideDelay: 0.5)
    visibility.scroll(to: 0, at: 10)
    XCTAssertFalse(visibility.isShown(at: 10), "最初に受けた位置は変化に数えない")
    visibility.scroll(to: 0, at: 11)
    XCTAssertFalse(visibility.isShown(at: 11), "同じ位置は変化ではない")

    visibility.scroll(to: 40, at: 12)
    XCTAssertTrue(visibility.isShown(at: 12.4))
    XCTAssertEqual(visibility.hidesAt(12.4), 12.5, "止まってから hideDelay 後に消え始める")
    XCTAssertFalse(visibility.isShown(at: 12.5))
    XCTAssertNil(visibility.hidesAt(12.5))
  }

  func testHoverAndDragKeepItShownAndReleaseStartsHidingAtOnce() {
    var visibility = Visibility(hideDelay: 0.5)
    visibility.scroll(to: 0, at: 0)
    visibility.hover(true, at: 1)
    XCTAssertTrue(visibility.isShown(at: 100), "ポインタが一覧の上にある間は見え続ける")
    XCTAssertNil(visibility.hidesAt(100), "ポインタがある間は消え始める時刻を持たない")

    visibility.scroll(to: 20, at: 100)
    visibility.hover(false, at: 100.1)
    XCTAssertFalse(visibility.isShown(at: 100.1), "出たらすぐ消え始める（直前のスクロールで見せ続けない）")

    visibility.drag(true, at: 101)
    visibility.scroll(to: 60, at: 101.2)
    XCTAssertTrue(visibility.isShown(at: 200), "ドラッグ中は見え続ける")
    visibility.drag(false, at: 200)
    XCTAssertFalse(visibility.isShown(at: 200), "ドラッグを離したらすぐ消え始める")
  }

  func testGeometryClampsThePositionDuringTheRubberBand() {
    let above = SidebarScrollbar.Metrics(position: -30, total: 1000, visible: 200).geometry
    XCTAssertEqual(above.sliderPosition, 0, "上へ弾んでもつまみは上端")
    let below = SidebarScrollbar.Metrics(position: 900, total: 1000, visible: 200).geometry
    XCTAssertEqual(
      below.sliderPosition + below.sliderLength, 200, "下へ弾んでもつまみは下端")
  }

  /// 溢れたツリー（41 行・見えている 192pt）を載せた、前に出した窓。
  private struct Tree {
    let pane: EditorPaneView
    let window: NSWindow
    let scroll: NSScrollView
    let document: NSView

    func move(to y: CGFloat) {
      scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
      scroll.reflectScrolledClipView(scroll.contentView)
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func geometry(at y: CGFloat) -> ScrollbarGeometry {
      SidebarScrollbar.Metrics(
        position: y, total: document.frame.height, visible: scroll.documentVisibleRect.height
      ).geometry
    }

    func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
  }

  private func hostTree() throws -> Tree {
    let dir = TestScratch.caseDir
    for index in 0..<40 {
      try FileManager.default.createDirectory(
        at: dir.appendingPathComponent(String(format: "d%02d", index)),
        withIntermediateDirectories: true)
    }
    let tab = TerminalTab.alone(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900, height: 240)
    window.orderFront(nil)
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    let scroll = try XCTUnwrap(scrollView(in: tab.group.view.editor.sideHost))
    let document = try XCTUnwrap(scroll.documentView)
    pumpMain(until: { document.frame.height > scroll.documentVisibleRect.height * 2 }, "ツリーが溢れる")
    return Tree(pane: tab.group.view.editor, window: window, scroll: scroll, document: document)
  }

  /// 今の位置のつまみの中央（窓の座標）。
  private func thumbCenter(_ tree: Tree) throws -> NSPoint {
    let frame = try XCTUnwrap(treeThumbFrame(tree.pane))
    return NSPoint(x: frame.midX, y: frame.midY)
  }

  /// ポインタを `point`（窓の座標）へ。
  private func hover(_ tree: Tree, _ point: NSPoint) {
    movePointer(tree.pane, to: tree.pane.convert(point, from: nil), over: tree.pane.sideHost)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  }

  /// ポインタを乗せたツリーのつまみの上でホイールを回すとツリーが送られる（つまみは当たりを持たない）。
  func testTheWheelOverTheTreeThumbScrollsTheTree() throws {
    let tree = try hostTree()
    tree.move(to: 100)
    let wheel = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0,
        wheel3: 0))
    let point = try thumbCenter(tree)
    hover(tree, point)
    wheel.location = CGPoint(x: point.x, y: (tree.window.screen?.frame.height ?? 0) - point.y)
    tree.window.sendEvent(try XCTUnwrap(NSEvent(cgEvent: wheel)))
    pumpMain(until: { tree.scroll.documentVisibleRect.minY > 100 }, "ツリーが送られる")
  }

  /// ツリーのつまみを掴んで引くと移動ぶんだけ連続に送られ、末尾まで引けば最後の行の下の 1 行分の空きまで届く。
  func testDraggingTheTreeThumbScrollsByTheDistance() throws {
    let tree = try hostTree()
    let start = try thumbCenter(tree)
    hover(tree, start)
    NSApp.sendEvent(tree.mouse(.leftMouseDown, start))
    for step in 1...10 {
      NSApp.sendEvent(
        tree.mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y - CGFloat(step) * 5)))
      RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
    XCTAssertEqual(
      tree.scroll.documentVisibleRect.minY, tree.geometry(at: 0).position(afterDragging: 50),
      accuracy: 1)
    let end = NSPoint(x: start.x, y: start.y - 1000)
    NSApp.sendEvent(tree.mouse(.leftMouseDragged, end))
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(
      tree.scroll.documentVisibleRect.maxY, tree.document.frame.height, accuracy: 1, "末尾まで届く")
    XCTAssertEqual(
      tree.document.frame.height, CGFloat(tree.pane.tree.rows.count + 1) * Theme.Layout.editorRow,
      accuracy: 1, "末尾は最後の行の下の 1 行分の空き")
    NSApp.sendEvent(tree.mouse(.leftMouseUp, end))
  }

  /// 掴めるのは見えているつまみだけ——つまみを押しても下の行は選ばれず、帯のつまみの外を押せばその行が選ばれる。
  func testOnlyTheTreeThumbIsGrabbedAndTheRestOfTheBandSelectsTheRow() throws {
    let tree = try hostTree()
    func click(_ point: NSPoint) {
      hover(tree, point)
      NSApp.sendEvent(tree.mouse(.leftMouseDown, point))
      NSApp.sendEvent(tree.mouse(.leftMouseUp, point))
      RunLoop.main.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.1))
    }
    let position: CGFloat = 100
    tree.move(to: position)
    let thumb = try XCTUnwrap(treeThumbFrame(tree.pane))
    click(NSPoint(x: thumb.midX, y: thumb.midY))
    XCTAssertNil(tree.pane.tree.selected, "つまみ")

    let band = NSPoint(x: thumb.midX, y: thumb.minY - Theme.Layout.editorRow)
    click(band)
    let bandY = tree.scroll.convert(band, from: nil).y
    let row = tree.pane.tree.rows[Int((position + bandY) / Theme.Layout.editorRow)]
    XCTAssertEqual(tree.pane.tree.selected, row.id, "帯のつまみの外")
  }
}
