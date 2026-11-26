import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 左の列の幅——開いていれば面の幅に関係なく出て、狭い面では表示幅を本体の最低幅が残るまで切り詰め（記憶は
/// 変えない）、境の当たりのドラッグは描かれている境から追従する。SwiftUI の中身が pane の決めた幅を埋めているかは
/// 描画で見る。
///
/// 壊れると何が起きるか。狭い面で左の列の表示幅が切り詰まらないと本体が潰れる。中身が固定幅を持つと境の線が
/// 古い位置に残る。切り詰め中に境を掴むと記憶の幅が黙って書き換わり永続する。
@MainActor
final class EditorPaneViewSidebarTests: OrbeTestCase {
  /// 上のバーの高さと、左の列の既定の幅に右の hairline を足した幅。
  private let bar: CGFloat = 36
  private let side: CGFloat = 264

  func testSidebarStaysOpenInNarrowColumnsWithItsShownWidthTrimmed() throws {
    let root = TestScratch.caseDir.path  // 空の根（描画の標本がツリーに被らない）
    let tab = TerminalTab.alone(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    let window = hostEditor(tab, width: 900)

    XCTAssertTrue(pane.sidebar.isOpen)
    XCTAssertEqual(
      pane.bodyRect, NSRect(x: side, y: bar, width: 900 - side, height: 400 - bar),
      "本体の上端はバーのすぐ下、左端は左の列の右の hairline の外側")
    let wide = try probe(pane) { p in try !PaneProbe.same(p.rgb(60), p.rgb(side + 60)) }
    let explorerGround = try wide.rgb(60)

    let document = try tab.group.editor.open(try caseFile("a.swift", "let a = 1\n"), as: .pinned)
    tab.group.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.bodyRect.minY, bar, "文書があっても本体の上端はバーのすぐ下")
    XCTAssertEqual(document.surface.view.frame, pane.bodyRect)

    window.setContentSize(NSSize(width: 360, height: 400))
    tab.group.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.sidebar.isOpen, "狭い面でも隠れない")
    XCTAssertEqual(pane.shownSidebarWidth, 360 - 1 - 160, "本体に 160 残るまで表示幅を切り詰める")
    XCTAssertEqual(pane.bodyRect.minX, 199 + 1)
    XCTAssertEqual(pane.bodyRect.width, 160)
    XCTAssertEqual(pane.sidebar.width, 263, "記憶の幅は変えない")
    XCTAssertEqual(document.surface.view.frame, pane.bodyRect)
    try assertSidebarContentFills(pane, width: 199)

    window.setContentSize(NSSize(width: 120, height: 400))
    tab.group.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.shownSidebarWidth, 0, "極端な幅では残りをそのまま分け、0 まで縮む")
    XCTAssertTrue(pane.sidebar.isOpen, "見えるかは開閉だけで決まる（面の幅は関係ない）")
    XCTAssertEqual(pane.bodyRect.minX, 1)
    try assertSidebarContentIsGone(pane, explorerGround: explorerGround)

    window.setContentSize(NSSize(width: 900, height: 400))
    tab.group.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.shownSidebarWidth, 263, "広がれば記憶の幅に戻る")
    XCTAssertEqual(pane.bodyRect.minX, side)

    pane.toggleSidebar()
    tab.group.view.layoutSubtreeIfNeeded()
    XCTAssertFalse(pane.sidebar.isOpen, "バーの左端で閉じる")
    XCTAssertEqual(pane.bodyRect.minX, 0, "本体が全幅になる")
    XCTAssertEqual(document.surface.view.frame, pane.bodyRect)

    pane.toggleSidebar()
    tab.group.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.sidebar.isOpen, "もう一度押すと開く")
    XCTAssertEqual(pane.bodyRect.minX, side, "閉じる前の幅で開く")
  }

  /// 切り詰め中のドラッグ。起点は描かれている境で記憶ではなく、境が動かないドラッグと下限までも出せない面では
  /// 記憶に触れない。
  func testDraggingInATrimmedColumnStartsFromTheDrawnEdge() throws {
    let root = TestScratch.caseDir.path
    let tab = TerminalTab.alone(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    let window = hostEditor(tab, width: 360)
    XCTAssertEqual(pane.shownSidebarWidth, 199)

    let handle = try XCTUnwrap(pane.belowBar.subviews.first { $0 is SidebarResizeHandle })
    XCTAssertEqual(handle.frame.minX, 199 - 2, "当たりは描かれている境に居る")
    XCTAssertFalse(handle.isHidden)
    handle.cursorUpdate(with: .mouse(.mouseMoved, at: panePoint(pane, 199), in: window))
    XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight, "境の当たりは左右矢印のカーソルを出す")
    handle.mouseDown(with: .mouse(.leftMouseDown, at: panePoint(pane, 199), in: window))
    handle.mouseDragged(
      with: .mouse(.leftMouseDragged, at: panePoint(pane, 199 + 40), in: window))
    XCTAssertEqual(pane.shownSidebarWidth, 199, "上限に押し付けても境は動かない")
    XCTAssertEqual(pane.sidebar.width, 263, "境が動かないドラッグは記憶に触れない")
    handle.mouseDragged(
      with: .mouse(.leftMouseDragged, at: panePoint(pane, 199 - 2), in: window))
    XCTAssertEqual(pane.shownSidebarWidth, 197, "境はポインタに追従する（起点は 199）")
    XCTAssertEqual(pane.sidebar.width, 197, "境を動かせば記憶もそこへ")
    handle.mouseUp(with: .mouse(.leftMouseUp, at: panePoint(pane, 197), in: window))
    pane.sidebar.setWidth(263)
    pane.sidebar.commit()

    window.setContentSize(NSSize(width: 300, height: 400))
    tab.group.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.shownSidebarWidth, 139, "下限 160 を割って切り詰まる")
    XCTAssertTrue(handle.isHidden, "下限までも出せない面では当たりを出さない（本体の左 1pt を覆わない）")
    handle.mouseDown(with: .mouse(.leftMouseDown, at: panePoint(pane, 139), in: window))
    handle.mouseDragged(
      with: .mouse(.leftMouseDragged, at: panePoint(pane, 139 - 50), in: window))
    XCTAssertEqual(pane.shownSidebarWidth, 139, "下限までも出せない面では動かない")
    XCTAssertEqual(pane.sidebar.width, 263, "動かないので記憶にも触れない")
    handle.mouseUp(with: .mouse(.leftMouseUp, at: panePoint(pane, 89), in: window))
  }

  /// 境の当たりをドラッグすると左の列の幅が連続で追従し、下限 160 と「本体に 160 残る」上限で止まり、
  /// 離すと書き戻す。幅はアプリ全体で 1 つなので、同じ状態を配られた別の面も同じ幅になる。
  func testDraggingTheHandleResizesTheSidebarWithinBounds() throws {
    let state = EditorSidebarState()
    let root = TestScratch.caseDir.path  // 空の根（描画の標本がツリーに被らない）
    let tab = TerminalTab.alone(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let other = TerminalTab.alone(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    for t in [tab, other] {
      t.group.view.configure(
        translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
        fontResolver: ChromeFontResolver(), sidebar: state)
    }
    let pane = tab.group.view.editor
    let window = hostEditor(tab, width: 900)

    let handle = try XCTUnwrap(pane.belowBar.subviews.first { $0 is SidebarResizeHandle })
    XCTAssertFalse(handle.isHidden)
    XCTAssertEqual(
      handle.frame, NSRect(x: 263 - 2, y: bar, width: 4, height: 400 - bar),
      "hairline を跨ぐ 4pt（バーの下だけ）")
    let hit = pane.hitTest(pane.convert(NSPoint(x: 263, y: 200), to: pane.superview))
    XCTAssertTrue(hit === handle, "境は当たりが受ける")
    let document = try tab.group.editor.open(try caseFile("a.swift", "let a = 1\n"), as: .pinned)
    tab.group.view.layoutSubtreeIfNeeded()
    let edge = pane.hitTest(
      pane.convert(NSPoint(x: pane.bodyRect.minX + 0.5, y: 200), to: pane.superview))
    XCTAssertTrue(edge === handle, "文書を開いていても当たりの右 1pt はテキスト面に覆われない")
    tab.group.editor.close(document)
    tab.group.view.layoutSubtreeIfNeeded()

    func point(_ x: CGFloat) -> NSPoint { panePoint(pane, x) }
    handle.mouseDown(with: .mouse(.leftMouseDown, at: point(263), in: window))
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: point(263 + 60), in: window))
    XCTAssertEqual(state.width, 323, "引いた距離だけ広がる")
    XCTAssertEqual(pane.bodyRect.minX, 324, "その場で置き直す")
    XCTAssertEqual(handle.frame.minX, 323 - 2, "当たりも境に付いてくる")
    try assertSidebarContentFills(pane, width: 323)
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: point(263 - 200), in: window))
    XCTAssertEqual(state.width, 160, "下限")
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: point(263 + 600), in: window))
    XCTAssertEqual(state.width, 900 - 1 - 160, "本体に 160 残るまで")
    handle.mouseUp(with: .mouse(.leftMouseUp, at: point(263 + 600), in: window))

    hostEditor(other, width: 900)
    XCTAssertEqual(other.group.view.editor.bodyRect.minX, 739 + 1, "同じ状態を配られた面は同じ幅")
  }

  /// バーの左端で閉じれば SwiftUI の中身（エクスプローラーの地）も消えて本体が全幅になり、もう一度押せば地・境の線が
  /// 戻る。pane の矩形が動いても中身が追随しなければ、閉じた後にエクスプローラーの地が本体に残る／開いた後に本体の地だけが
  /// 見える。置き直しは観測の非同期ホップを待つ。
  func testToggleRemovesAndRestoresTheExplorerContent() throws {
    let root = TestScratch.caseDir.path
    let tab = TerminalTab.alone(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    hostEditor(tab, width: 900)
    let open = try probe(pane) { p in try !PaneProbe.same(p.rgb(60), p.rgb(side + 60)) }
    let explorerGround = try open.rgb(60)

    func settled(_ bodyMinX: CGFloat, _ message: String) {
      pumpMain(
        until: {
          tab.group.view.layoutSubtreeIfNeeded()
          return pane.bodyRect.minX == bodyMinX
        }, message)
    }
    pane.toggleSidebar()
    settled(0, "閉じれば本体が全幅")
    let closed = try probe(pane) { p in try !PaneProbe.same(p.rgb(60), explorerGround) }
    XCTAssertFalse(PaneProbe.same(try closed.rgb(60), explorerGround), "エクスプローラーの地は消える")
    XCTAssertTrue(
      PaneProbe.same(try closed.rgb(60), try closed.rgb(pane.bodyRect.midX)), "本体の地が続く")

    pane.toggleSidebar()
    settled(side, "開けば戻る")
    let reopened = try probe(pane) { p in try PaneProbe.same(p.rgb(60), explorerGround) }
    XCTAssertTrue(PaneProbe.same(try reopened.rgb(60), explorerGround), "エクスプローラーの地が戻る")
    try assertSidebarContentFills(pane, width: 263)
  }

  /// ⌘⇧B はエディターにフォーカスがある間だけ左の列を開閉し、フォーカスが面の外にあれば素通しする。
  func testCommandShiftBTogglesTheSidebarOnlyWhileTheEditorHasTheFocus() throws {
    let tab = TerminalTab.alone(
      cwd: TestScratch.caseDir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    let window = hostEditor(tab, width: 900)
    let commandShiftB = NSEvent.key("B", [.command, .shift])

    window.makeFirstResponder(pane)
    XCTAssertTrue(pane.performKeyEquivalent(with: commandShiftB))
    XCTAssertFalse(pane.sidebar.isOpen, "閉じる")
    XCTAssertTrue(pane.performKeyEquivalent(with: commandShiftB))
    XCTAssertTrue(pane.sidebar.isOpen, "開く")

    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    tab.group.view.addSubview(outsider)
    XCTAssertTrue(window.makeFirstResponder(outsider))
    XCTAssertFalse(pane.performKeyEquivalent(with: commandShiftB), "面の外のフォーカスには効かない")
    XCTAssertTrue(pane.sidebar.isOpen)
  }

  /// 幅と開閉はアプリ全体で 1 つ——既に窓に載っている別の連の面も、ドラッグと開閉に追随する（置き直しは
  /// 観測の非同期ホップ越し。自分でドラッグした面だけがその場で置き直す）。
  func testSharedSidebarStateMovesEveryHostedPane() throws {
    let state = EditorSidebarState()
    let root = TestScratch.caseDir.path
    let tab = TerminalTab.alone(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let other = TerminalTab.alone(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    for t in [tab, other] {
      t.group.view.configure(
        translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
        fontResolver: ChromeFontResolver(), sidebar: state)
    }
    let pane = tab.group.view.editor
    let otherPane = other.group.view.editor
    let window = hostEditor(tab, width: 900)
    hostEditor(other, width: 900)
    func settled(_ bodyMinX: CGFloat, _ message: String) {
      pumpMain(
        until: {
          other.group.view.layoutSubtreeIfNeeded()
          tab.group.view.layoutSubtreeIfNeeded()
          return otherPane.bodyRect.minX == bodyMinX && pane.bodyRect.minX == bodyMinX
        }, message)
    }

    let handle = try XCTUnwrap(pane.belowBar.subviews.first { $0 is SidebarResizeHandle })
    handle.mouseDown(with: .mouse(.leftMouseDown, at: panePoint(pane, 263), in: window))
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: panePoint(pane, 263 + 60), in: window))
    handle.mouseUp(with: .mouse(.leftMouseUp, at: panePoint(pane, 263 + 60), in: window))
    settled(324, "片方で引けばもう片方の面も同じ幅へ")
    try assertSidebarContentFills(otherPane, width: 323)

    otherPane.toggleSidebar()
    settled(0, "片方で閉じればもう片方も閉じる")
    otherPane.toggleSidebar()
    settled(324, "開けば記憶の幅で戻る")
  }

  /// SwiftUI の中身（エクスプローラーの地と右の hairline）が pane の決めた表示幅を埋めているかを描画で見る。
  /// pane の矩形が動いても中身が固定幅のままなら、右の線が古い位置に残り、新しい境には地しか無い。
  private func assertSidebarContentFills(_ pane: EditorPaneView, width: CGFloat) throws {
    let drawn = try probe(pane) { p in
      let ground = try p.rgb(60)
      return try PaneProbe.same(p.rgb(width - 2), ground)
        && !PaneProbe.same(p.rgb(width + 0.5), ground)
    }
    let ground = try drawn.rgb(60)
    XCTAssertTrue(PaneProbe.same(try drawn.rgb(width - 2), ground), "境の手前まで地が続く")
    XCTAssertFalse(PaneProbe.same(try drawn.rgb(width + 0.5), ground), "境に hairline がある")
    if width > 263 {
      XCTAssertTrue(
        PaneProbe.same(try drawn.rgb(263 - 2), ground), "既定の幅 263 の位置には線が残らない")
      XCTAssertTrue(PaneProbe.same(try drawn.rgb(263 + 0.5), ground))
    }
  }

  /// 表示幅 0: エクスプローラーの地がどこにも無い（本体の地が続く）。
  private func assertSidebarContentIsGone(_ pane: EditorPaneView, explorerGround: [Int]) throws {
    let drawn = try probe(pane) { p in try !PaneProbe.same(p.rgb(50), explorerGround) }
    let body = try drawn.rgb(50)
    XCTAssertFalse(PaneProbe.same(body, explorerGround), "エクスプローラーの地は無い")
    XCTAssertTrue(PaneProbe.same(try drawn.rgb(100), body), "本体の地が続く（はみ出しが無い）")
  }
}
