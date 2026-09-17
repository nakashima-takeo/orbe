import AppKit
import XCTest

@testable import Orbe

/// サイドバーの幅——開いていれば列幅に関係なく出て、狭い列では表示幅を本体の最低幅が残るまで切り詰め（記憶は
/// 変えない）、境の当たりのドラッグは描かれている境から追従する。SwiftUI の中身が pane の決めた幅を埋めているかは
/// 描画で見る。
///
/// 壊れると何が起きるか。狭い面でサイドバーの表示幅が切り詰まらないと本体が潰れる。中身が固定幅を持つと境の線が
/// 古い位置に残る。切り詰め中に境を掴むと記憶の幅が黙って書き換わり永続する。
@MainActor
final class EditorPaneViewSidebarTests: OrbeTestCase {
  func testSidebarStaysOpenInNarrowColumnsWithItsShownWidthTrimmed() throws {
    let root = try XCTUnwrap(TestIsolation.caseDir).path  // 空の根（描画の標本がツリーに被らない）
    let tab = TerminalTab(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }

    XCTAssertTrue(pane.sidebar.isOpen)
    XCTAssertEqual(
      pane.bodyRect, NSRect(x: 37 + 241, y: 29, width: 900 - 278, height: 400 - 2 - 29),
      "レール・サイドバーの右、タブ行の下の hairline はその外側")
    let wide = try PaneProbe(pane)
    let railGround = try wide.rgb(18)
    let explorerGround = try wide.rgb(37 + 60)

    let document = try tab.editor.open(try caseFile("a.swift", "let a = 1\n"))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.bodyRect.minY, 29 + 20, "文書があればパンくずの分だけ下がる")
    XCTAssertEqual(document.surface.view.frame, pane.bodyRect)

    window.setContentSize(NSSize(width: 360 + FaceGeometry.spine, height: 400))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.sidebar.isOpen, "狭い列でも隠れない")
    XCTAssertEqual(pane.shownSidebarWidth, 360 - 36 - 2 - 160, "本体に 160 残るまで表示幅を切り詰める")
    XCTAssertEqual(pane.bodyRect.minX, 37 + 162 + 1)
    XCTAssertEqual(pane.bodyRect.width, 160)
    XCTAssertEqual(pane.sidebar.width, 240, "記憶の幅は変えない")
    XCTAssertEqual(document.surface.view.frame, pane.bodyRect)
    try assertSidebarContentFills(pane, width: 162)

    window.setContentSize(NSSize(width: 120 + FaceGeometry.spine, height: 400))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.shownSidebarWidth, 0, "極端な幅では残りをそのまま分け、0 まで縮む")
    XCTAssertTrue(pane.sidebar.isOpen, "見えるかは開閉だけで決まる（列幅は関係ない）")
    XCTAssertEqual(pane.bodyRect.minX, 37 + 1)
    try assertSidebarContentIsGone(pane, railGround: railGround, explorerGround: explorerGround)

    window.setContentSize(NSSize(width: 900 + FaceGeometry.spine, height: 400))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.shownSidebarWidth, 240, "広がれば記憶の幅に戻る")
    XCTAssertEqual(pane.bodyRect.minX, 37 + 241)

    pane.shell.toggleSidebar()
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertFalse(pane.sidebar.isOpen, "レールの選択中の項目を押すと閉じる")
    XCTAssertEqual(pane.bodyRect.minX, 37, "レールだけ残る")
    XCTAssertEqual(document.surface.view.frame, pane.bodyRect)

    pane.shell.toggleSidebar()
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.sidebar.isOpen, "もう一度押すと開く")
    XCTAssertEqual(pane.bodyRect.minX, 37 + 241)
  }

  /// 切り詰め中のドラッグ。起点は描かれている境で記憶ではなく、境が動かないドラッグと下限までも出せない列では
  /// 記憶に触れない。
  func testDraggingInATrimmedColumnStartsFromTheDrawnEdge() throws {
    let root = try XCTUnwrap(TestIsolation.caseDir).path
    let tab = TerminalTab(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 360)
    defer { window.orderOut(nil) }
    XCTAssertEqual(pane.shownSidebarWidth, 162)

    let handle = try XCTUnwrap(pane.subviews.first { $0 is SidebarResizeHandle })
    XCTAssertEqual(handle.frame.minX, 37 + 162 - 2, "当たりは描かれている境に居る")
    handle.mouseDown(with: .mouse(.leftMouseDown, at: panePoint(pane, 37 + 162), in: window))
    handle.mouseDragged(
      with: .mouse(.leftMouseDragged, at: panePoint(pane, 37 + 162 + 40), in: window))
    XCTAssertEqual(pane.shownSidebarWidth, 162, "上限に押し付けても境は動かない")
    XCTAssertEqual(pane.sidebar.width, 240, "境が動かないドラッグは記憶に触れない")
    handle.mouseDragged(
      with: .mouse(.leftMouseDragged, at: panePoint(pane, 37 + 162 - 2), in: window))
    XCTAssertEqual(pane.shownSidebarWidth, 160, "境はポインタに追従する（起点は 162）")
    XCTAssertEqual(pane.sidebar.width, 160, "境を動かせば記憶もそこへ")
    handle.mouseUp(with: .mouse(.leftMouseUp, at: panePoint(pane, 37 + 160), in: window))
    pane.sidebar.setWidth(240)
    pane.sidebar.commit()

    window.setContentSize(NSSize(width: 340 + FaceGeometry.spine, height: 400))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.shownSidebarWidth, 142, "下限 160 を割って切り詰まる")
    handle.mouseDown(with: .mouse(.leftMouseDown, at: panePoint(pane, 37 + 142), in: window))
    handle.mouseDragged(
      with: .mouse(.leftMouseDragged, at: panePoint(pane, 37 + 142 - 50), in: window))
    XCTAssertEqual(pane.shownSidebarWidth, 142, "下限までも出せない列では動かない")
    XCTAssertEqual(pane.sidebar.width, 240, "動かないので記憶にも触れない")
    handle.mouseUp(with: .mouse(.leftMouseUp, at: panePoint(pane, 37 + 92), in: window))

  }

  /// 境の当たりをドラッグするとサイドバーの幅が連続で追従し、下限 160 と「本体に 160 残る」上限で止まり、
  /// 離すと書き戻す。幅はアプリ全体で 1 つなので、同じ状態を配られた別の面も同じ幅になる。
  func testDraggingTheHandleResizesTheSidebarWithinBounds() throws {
    let state = EditorSidebarState()
    let root = try XCTUnwrap(TestIsolation.caseDir).path  // 空の根（描画の標本がツリーに被らない）
    let tab = TerminalTab(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let other = TerminalTab(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    for t in [tab, other] {
      t.view.configure(
        translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
        fontResolver: ChromeFontResolver(), sidebar: state)
    }
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }

    let handle = try XCTUnwrap(pane.subviews.first { $0 is SidebarResizeHandle })
    XCTAssertFalse(handle.isHidden)
    XCTAssertEqual(
      handle.frame, NSRect(x: 37 + 240 - 2, y: 0, width: 4, height: 398), "hairline を跨ぐ 4pt")
    let hit = pane.hitTest(pane.convert(NSPoint(x: 37 + 240, y: 200), to: pane.superview))
    XCTAssertTrue(hit === handle, "境は当たりが受ける")
    let document = try tab.editor.open(try caseFile("a.swift", "let a = 1\n"))
    tab.view.layoutSubtreeIfNeeded()
    let edge = pane.hitTest(
      pane.convert(NSPoint(x: pane.bodyRect.minX + 0.5, y: 200), to: pane.superview))
    XCTAssertTrue(edge === handle, "文書を開いていても当たりの右 1pt はテキスト面に覆われない")
    tab.editor.close(document)
    tab.view.layoutSubtreeIfNeeded()

    func point(_ x: CGFloat) -> NSPoint { panePoint(pane, x) }
    handle.mouseDown(with: .mouse(.leftMouseDown, at: point(278), in: window))
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: point(278 + 60), in: window))
    XCTAssertEqual(state.width, 300, "引いた距離だけ広がる")
    XCTAssertEqual(pane.bodyRect.minX, 37 + 301, "その場で置き直す")
    XCTAssertEqual(handle.frame.minX, 37 + 300 - 2, "当たりも境に付いてくる")
    try assertSidebarContentFills(pane, width: 300)
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: point(278 - 200), in: window))
    XCTAssertEqual(state.width, 160, "下限")
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: point(278 + 600), in: window))
    XCTAssertEqual(state.width, 900 - 36 - 2 - 160, "本体に 160 残るまで")
    handle.mouseUp(with: .mouse(.leftMouseUp, at: point(278 + 600), in: window))

    let otherWindow = hostEditor(other, width: 900)
    defer { otherWindow.orderOut(nil) }
    XCTAssertEqual(other.view.editor.bodyRect.minX, 37 + 702 + 1, "同じ状態を配られた面は同じ幅")
  }

  /// レールの「ファイル」で閉じれば SwiftUI の中身（エクスプローラーの地）も消えてレールの選択印（左縁の accent）が
  /// 無くなり、もう一度押せば地・境の線・選択印が戻る。pane の矩形が動いても中身が追随しなければ、閉じた後に
  /// エクスプローラーの地が本体に残る／開いた後に本体の地だけが見える。置き直しは観測の非同期ホップを待つ。
  func testRailToggleRemovesAndRestoresTheExplorerContentAndTheSelectionMark() throws {
    let root = try XCTUnwrap(TestIsolation.caseDir).path
    let tab = TerminalTab(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }
    let open = try PaneProbe(pane)
    let railGround = try open.rgb(18, y: 60)
    let explorerGround = try open.rgb(37 + 60)
    XCTAssertFalse(PaneProbe.same(try open.rgb(1, y: 18), railGround), "開いていれば左縁に選択印")
    XCTAssertFalse(PaneProbe.same(try open.rgb(18, y: 18), railGround), "選択項目の淡い地")

    func settled(_ bodyMinX: CGFloat, _ message: String) {
      pumpMain(
        until: {
          tab.view.layoutSubtreeIfNeeded()
          return pane.bodyRect.minX == bodyMinX
        }, message)
    }
    pane.shell.toggleSidebar()
    settled(37, "閉じればレールだけ")
    let closed = try PaneProbe(pane)
    XCTAssertTrue(PaneProbe.same(try closed.rgb(1, y: 18), railGround), "閉じている間は選択印が無い")
    XCTAssertTrue(PaneProbe.same(try closed.rgb(18, y: 18), railGround))
    XCTAssertFalse(PaneProbe.same(try closed.rgb(37 + 60), explorerGround), "エクスプローラーの地は消える")
    XCTAssertTrue(
      PaneProbe.same(try closed.rgb(37 + 60), try closed.rgb(pane.bodyRect.midX)), "本体の地が続く")

    pane.shell.toggleSidebar()
    settled(37 + 241, "開けば戻る")
    let reopened = try PaneProbe(pane)
    XCTAssertFalse(PaneProbe.same(try reopened.rgb(1, y: 18), railGround), "選択印が戻る")
    XCTAssertTrue(PaneProbe.same(try reopened.rgb(37 + 60), explorerGround), "エクスプローラーの地が戻る")
    try assertSidebarContentFills(pane, width: 240)
  }

  /// 幅と開閉はアプリ全体で 1 つ——既に窓に載っている別のタブの面も、ドラッグと開閉に追随する（置き直しは
  /// 観測の非同期ホップ越し。自分でドラッグした面だけがその場で置き直す）。
  func testSharedSidebarStateMovesEveryHostedPane() throws {
    let state = EditorSidebarState()
    let root = try XCTUnwrap(TestIsolation.caseDir).path
    let tab = TerminalTab(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let other = TerminalTab(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    for t in [tab, other] {
      t.view.configure(
        translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
        fontResolver: ChromeFontResolver(), sidebar: state)
    }
    let pane = tab.view.editor
    let otherPane = other.view.editor
    let window = hostEditor(tab, width: 900)
    let otherWindow = hostEditor(other, width: 900)
    defer {
      window.orderOut(nil)
      otherWindow.orderOut(nil)
    }
    func settled(_ bodyMinX: CGFloat, _ message: String) {
      pumpMain(
        until: {
          other.view.layoutSubtreeIfNeeded()
          tab.view.layoutSubtreeIfNeeded()
          return otherPane.bodyRect.minX == bodyMinX && pane.bodyRect.minX == bodyMinX
        }, message)
    }

    let handle = try XCTUnwrap(pane.subviews.first { $0 is SidebarResizeHandle })
    handle.mouseDown(with: .mouse(.leftMouseDown, at: panePoint(pane, 278), in: window))
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: panePoint(pane, 278 + 60), in: window))
    handle.mouseUp(with: .mouse(.leftMouseUp, at: panePoint(pane, 278 + 60), in: window))
    settled(37 + 301, "片方で引けばもう片方の面も同じ幅へ")
    try assertSidebarContentFills(otherPane, width: 300)

    otherPane.shell.toggleSidebar()
    settled(37, "片方で閉じればもう片方も閉じる")
    otherPane.shell.toggleSidebar()
    settled(37 + 301, "開けば記憶の幅で戻る")
  }

  /// 面を描いて 1 行（ツリーの下の空き。根の行より下）の色を x で引く。
  private struct PaneProbe {
    let rep: NSBitmapImageRep
    let scale: CGFloat
    let y: Int

    init(_ pane: EditorPaneView) throws {
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))  // SwiftUI の描画コミット
      rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
      pane.cacheDisplay(in: pane.bounds, to: rep)
      scale = CGFloat(rep.pixelsWide) / pane.bounds.width
      y = Int((pane.bounds.height - 12) * scale)
    }

    func rgb(_ x: CGFloat, y row: CGFloat? = nil) throws -> [Int] {
      let y = row.map { Int($0 * scale) } ?? y
      let c = try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: y)?.usingColorSpace(.deviceRGB))
      return [c.redComponent, c.greenComponent, c.blueComponent].map { Int($0 * 255) }
    }

    static func same(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 2 } }
  }

  /// SwiftUI の中身（エクスプローラーの地と右の hairline）が pane の決めた表示幅を埋めているかを描画で見る。
  /// pane の矩形が動いても中身が固定幅のままなら、右の線が古い位置に残り、新しい境には地しか無い。
  private func assertSidebarContentFills(_ pane: EditorPaneView, width: CGFloat) throws {
    let probe = try PaneProbe(pane)
    let ground = try probe.rgb(37 + 60)
    let edge = 37 + width
    XCTAssertTrue(PaneProbe.same(try probe.rgb(edge - 2), ground), "境の手前まで地が続く")
    XCTAssertFalse(PaneProbe.same(try probe.rgb(edge + 0.5), ground), "境に hairline がある")
    if width > 240 {
      XCTAssertTrue(
        PaneProbe.same(try probe.rgb(37 + 240 - 2), ground), "既定の幅 240 の位置には線が残らない")
      XCTAssertTrue(PaneProbe.same(try probe.rgb(37 + 240 + 0.5), ground))
    }
  }

  /// 表示幅 0: レール（0〜36）はレールの地のまま、37 より右にエクスプローラーの地が無い（本体の地が続く）。
  private func assertSidebarContentIsGone(
    _ pane: EditorPaneView, railGround: [Int], explorerGround: [Int]
  ) throws {
    let probe = try PaneProbe(pane)
    XCTAssertTrue(PaneProbe.same(try probe.rgb(18), railGround), "レールの地は残る")
    let body = try probe.rgb(50)
    XCTAssertFalse(PaneProbe.same(body, explorerGround), "37 より右にエクスプローラーの地は無い")
    XCTAssertTrue(PaneProbe.same(try probe.rgb(100), body), "本体の地が続く（はみ出しが無い）")
  }
}
