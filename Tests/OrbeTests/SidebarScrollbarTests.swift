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

  /// 溢れたツリー（41 行・見えている 192pt）を載せ、`placeOffscreen` で並べた窓。
  private struct Tree {
    /// 連を生かしておく（面は連を弱く持つ）。
    let tab: TerminalTab
    let pane: EditorPaneView
    let window: NSWindow
    let scroll: NSScrollView
    let document: NSView

    func move(to y: CGFloat) {
      scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
      scroll.reflectScrolledClipView(scroll.contentView)
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

  /// `opening`（ツリーの根からの相対パス）を渡すと、そのファイルを作り、窓に載せる前に今の文書として開く。
  private func hostTree(opening: String? = nil) throws -> Tree {
    // 作業ディレクトリそのものには、隔離のハーネスと本番が置くファイルが在り、ツリーの行になる。
    let dir = TestScratch.caseDir.appendingPathComponent("tree")
    for index in 0..<40 {
      try FileManager.default.createDirectory(
        at: dir.appendingPathComponent(String(format: "d%02d", index)),
        withIntermediateDirectories: true)
    }
    let tab = TerminalTab.alone(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    if let opening {
      let file = dir.appendingPathComponent(opening)
      try "x\n".write(to: file, atomically: true, encoding: .utf8)
      _ = try tab.group.editor.open(file, as: .pinned)
    }
    let window = hostEditor(tab, width: 900, height: 240)
    placeOffscreen(window)
    let scroll = try XCTUnwrap(scrollView(in: tab.group.view.editor.sideHost))
    let document = try XCTUnwrap(scroll.documentView)
    pumpMain(until: { document.frame.height > scroll.documentVisibleRect.height * 2 }, "ツリーが溢れる")
    return Tree(
      tab: tab, pane: tab.group.view.editor, window: window, scroll: scroll, document: document)
  }

  /// 今の位置のつまみの中央（窓の座標）。
  private func thumbCenter(_ tree: Tree) throws -> NSPoint {
    let frame = try XCTUnwrap(treeThumbFrame(tree.pane))
    return NSPoint(x: frame.midX, y: frame.midY)
  }

  /// 位置 `position` へ送ったときの、つまみの枠（窓の座標）。
  private func thumbFrame(_ tree: Tree, at position: CGFloat) -> NSRect {
    let geometry = tree.geometry(at: position)
    let width = Theme.Layout.editorSidebarScrollbar
    return tree.scroll.convert(
      NSRect(
        x: tree.scroll.bounds.maxX - width, y: geometry.sliderPosition, width: width,
        height: geometry.sliderLength), to: nil)
  }

  /// つまみが、いまのスクロール位置の枠に描かれているか。枠の両端の内側で、つまみの列の画素がすぐ左の画素と違い、
  /// 両端の外側（一覧の中に在る側）では同じ。
  private func thumbIsDrawn(_ tree: Tree) -> Bool {
    guard let frame = treeThumbFrame(tree.pane), let probe = try? PaneProbe(tree.pane) else {
      return false
    }
    let track = tree.scroll.convert(tree.scroll.bounds, to: nil)
    func differs(_ y: CGFloat) -> Bool? {
      guard y > track.minY, y < track.maxY else { return nil }
      let on = tree.pane.convert(NSPoint(x: frame.midX, y: y), from: nil)
      let beside = tree.pane.convert(NSPoint(x: frame.minX - 6, y: y), from: nil)
      guard let a = try? probe.rgb(on.x, y: on.y), let b = try? probe.rgb(beside.x, y: beside.y)
      else { return nil }
      return !PaneProbe.same(a, b)
    }
    return differs(frame.minY + 2) == true && differs(frame.maxY - 2) == true
      && differs(frame.minY - 3) != true && differs(frame.maxY + 3) != true
  }

  /// ポインタを `point`（窓の座標）へ動かし、つまみが現れるまで待つ。つまみが隠れているとき（位置を送る前）に呼ぶ——
  /// 現れたことを、ホバーが届いた印として待つので、つまみが既に見えていると、待ちはホバーが届く前に成り立つ。
  private func hover(_ tree: Tree, _ point: NSPoint) {
    movePointer(tree.pane, to: tree.pane.convert(point, from: nil), over: tree.pane.sideHost)
    pumpMain(until: { thumbIsDrawn(tree) }, "ポインタを乗せると、つまみが現れる")
  }

  /// 位置 `position` へ送り、つまみがその位置に描かれるまで待つ。
  private func move(_ tree: Tree, to position: CGFloat) {
    tree.move(to: position)
    pumpMain(until: { thumbIsDrawn(tree) }, "つまみが、送った位置に描かれる")
  }

  /// ポインタを乗せたツリーのつまみの上でホイールを回すとツリーが送られる（つまみは当たりを持たない）。
  func testTheWheelOverTheTreeThumbScrollsTheTree() throws {
    let tree = try hostTree()
    let thumb = thumbFrame(tree, at: 100)
    hover(tree, NSPoint(x: thumb.midX, y: thumb.midY))
    move(tree, to: 100)
    let wheel = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: SyntheticInput.source, units: .line, wheelCount: 1, wheel1: -3,
        wheel2: 0,
        wheel3: 0))
    let point = try thumbCenter(tree)
    // CGEvent の座標は主ディスプレイの左上が原点。窓を持たない NSEvent の locationInWindow は、主ディスプレイの高さで
    // 上下を反転した値になるので、窓の座標 `point` がそのまま出るように逆算する。
    let flip = NSScreen.screens.first?.frame.height ?? 0
    wheel.location = CGPoint(x: point.x, y: flip - point.y)
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
    }
    let expected = tree.geometry(at: 0).position(afterDragging: 50)
    waitUntil(10) { abs(tree.scroll.documentVisibleRect.minY - expected) <= 1 }
    pumpMain(until: { thumbIsDrawn(tree) }, "つまみが、送られた位置に描かれる")
    XCTAssertEqual(
      tree.scroll.documentVisibleRect.minY, expected, accuracy: 1, "引いた 50pt ぶん送られる")
    let end = NSPoint(x: start.x, y: start.y - 1000)
    NSApp.sendEvent(tree.mouse(.leftMouseDragged, end))
    waitUntil(10) { abs(tree.scroll.documentVisibleRect.maxY - tree.document.frame.height) <= 1 }
    XCTAssertEqual(
      tree.scroll.documentVisibleRect.maxY, tree.document.frame.height, accuracy: 1, "末尾まで届く")
    XCTAssertEqual(
      tree.document.frame.height, CGFloat(tree.pane.tree.rows.count + 1) * Theme.Layout.editorRow,
      accuracy: 1, "末尾は最後の行の下の 1 行分の空き")
    NSApp.sendEvent(tree.mouse(.leftMouseUp, end))
  }

  /// 左の列の中身を替えて・左の列を閉じて戻すと、作り直したツリーは前のスクロール位置に戻る。
  func testTheTreeKeepsItsScrollPositionAcrossPanelChangesAndClosing() throws {
    let tree = try hostTree()
    tree.move(to: 100)
    let pane = tree.pane
    for (name, away, back) in [
      ("中身を替える", { pane.filesPanel = .search }, { pane.filesPanel = .files }),
      ("左の列を閉じる", { pane.toggleSidebar() }, { pane.toggleSidebar() }),
    ] {
      away()
      pumpMain(until: { self.scrollView(in: pane.sideHost) !== tree.scroll }, "\(name): ツリーが外れる")
      back()
      pumpMain(
        until: {
          guard let scroll = self.scrollView(in: pane.sideHost), scroll !== tree.scroll else {
            return false
          }
          return abs(scroll.documentVisibleRect.minY - 100) < 1
        }, "\(name): 作り直したツリーが前の位置に戻る")
    }
  }

  /// ツリーを初めて出すとき、今の文書が在ればその行を見せ、無ければ先頭から出す。
  func testTheFirstTreeShowsTheRowOfTheCurrentDocument() throws {
    let tree = try hostTree(opening: "d38/f.txt")
    XCTAssertEqual(tree.pane.tree.selected, "d38/f.txt", "前提: 今の文書の行が選ばれている")
    pumpMain(
      until: {
        guard let row = tree.pane.tree.rows.firstIndex(where: { $0.id == "d38/f.txt" }) else {
          return false
        }
        let top = CGFloat(row) * Theme.Layout.editorRow
        let visible = tree.scroll.documentVisibleRect
        return top >= visible.minY && top + Theme.Layout.editorRow <= visible.maxY
      }, "初めて出したツリーが、今の文書の行を見せる")

    let bare = try hostTree()
    XCTAssertNil(bare.pane.tree.selected, "前提: 今の文書が無い")
    // 行を見せる送りは、最初のレイアウトの後に main のキューへ積まれる。積まれていれば、ここで走り終える。
    nextTurn()
    XCTAssertEqual(bare.scroll.documentVisibleRect.minY, 0, "今の文書が無ければ先頭から出す")
  }

  /// エクスプローラーが隠れている間に今の文書が替われば、作り直したツリーはその行を見せる。その後に送った位置は、今の文書が
  /// 替わらないまま隠れて戻れば、そのまま戻る（選択の行を見せ直さない）。
  func testTheRebuiltTreeShowsTheRowOfADocumentOpenedWhileItWasHidden() throws {
    let tree = try hostTree()
    let pane = tree.pane
    let file = TestScratch.caseDir.appendingPathComponent("tree/d38/f.txt")
    try "x\n".write(to: file, atomically: true, encoding: .utf8)
    func rebuiltScroll() -> NSScrollView? {
      guard let scroll = scrollView(in: pane.sideHost), scroll !== tree.scroll else { return nil }
      return scroll
    }

    pane.filesPanel = .search
    pumpMain(until: { self.scrollView(in: pane.sideHost) !== tree.scroll }, "ツリーが外れる")
    _ = try tree.tab.group.editor.open(file, as: .pinned)
    XCTAssertEqual(pane.tree.selected, "d38/f.txt", "前提: 隠れている間に選択が替わる")
    pane.showExplorer()
    pumpMain(
      until: {
        guard let scroll = rebuiltScroll(),
          let row = pane.tree.rows.firstIndex(where: { $0.id == "d38/f.txt" })
        else { return false }
        let top = CGFloat(row) * Theme.Layout.editorRow
        let visible = scroll.documentVisibleRect
        return top >= visible.minY && top + Theme.Layout.editorRow <= visible.maxY
      }, "作り直したツリーが、選択の行を見せる")
    let revealed = try XCTUnwrap(rebuiltScroll())
    let position: CGFloat = 20
    revealed.contentView.scroll(to: NSPoint(x: 0, y: position))
    revealed.reflectScrolledClipView(revealed.contentView)

    pane.filesPanel = .search
    pumpMain(until: { self.scrollView(in: pane.sideHost) !== revealed }, "ツリーが外れる")
    pane.showExplorer()
    pumpMain(
      until: {
        guard let scroll = self.scrollView(in: pane.sideHost), scroll !== revealed else {
          return false
        }
        return abs(scroll.documentVisibleRect.minY - position) < 1
      }, "選択が替わらなければ、前の位置に戻る")
  }

  /// 掴めるのは見えているつまみだけ——ポインタを乗せたつまみを押しても、下の行は選ばれない。
  func testPressingTheTreeThumbDoesNotSelectTheRowUnderIt() throws {
    let tree = try hostTree()
    let thumb = thumbFrame(tree, at: 100)
    let point = NSPoint(x: thumb.midX, y: thumb.midY)
    hover(tree, point)
    move(tree, to: 100)
    deliverClick(at: point, in: tree.window)
    XCTAssertNil(tree.pane.tree.selected, "つまみ")
  }

  /// 帯のつまみの外を押せば、その行が選ばれる。押すのは帯のうち行の上に重なる所（一覧の右の内側 6 には行が無い）。
  func testPressingTheBandOutsideTheTreeThumbSelectsTheRow() throws {
    let tree = try hostTree()
    let position: CGFloat = 100
    let thumb = thumbFrame(tree, at: position)
    let band = NSPoint(x: thumb.minX + 2, y: thumb.minY - Theme.Layout.editorRow)
    hover(tree, band)
    move(tree, to: position)
    deliverClick(at: band, in: tree.window)
    let bandY = tree.scroll.convert(band, from: nil).y
    let row = tree.pane.tree.rows[Int((position + bandY) / Theme.Layout.editorRow)]
    XCTAssertEqual(
      tree.pane.tree.selected, row.id,
      "帯のつまみの外を押せば、離すイベントの配送の中で行が選ばれる。これが待たずに成り立たなくなれば、"
        + "testPressingTheTreeThumbDoesNotSelectTheRowUnderIt の確かめる時点も成り立たない")
  }
}
