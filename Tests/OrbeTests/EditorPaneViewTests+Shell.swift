import AppKit
import XCTest

@testable import Orbe

/// 面の骨——pane が幾何を解き（レール｜サイドバー（開いているとき。狭い列では表示幅を切り詰める）｜列の頭｜本体）、骨の host はクリックを自分で
/// 受け、ツリーは面が窓に付いて隠れていない間だけ根のサービスを握り、cd で根が変わればツリーを作り直す。
///
/// 壊れると何が起きるか。hitTest が面全体を self に固定したままだと骨がクリックできない。隠れたタブの
/// ツリーが握り続けると全タブの根を常時監視する。狭い面でサイドバーの表示幅が切り詰まらないと本体が潰れる。
@MainActor
final class EditorPaneViewShellTests: OrbeTestCase {
  private func file(_ name: String, _ text: String) throws -> URL {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  /// 面の座標 x（y は中ほど）を窓座標へ。
  private func point(_ pane: EditorPaneView, _ x: CGFloat) -> NSPoint {
    pane.convert(NSPoint(x: x, y: 200), to: nil)
  }

  private func hosted(_ tab: TerminalTab, width: CGFloat) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width + FaceGeometry.spine, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = tab.view
    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    tab.view.layoutSubtreeIfNeeded()
    return window
  }

  func testSidebarStaysOpenInNarrowColumnsWithItsShownWidthTrimmed() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hosted(tab, width: 900)
    defer { window.orderOut(nil) }

    XCTAssertTrue(pane.shell.sidebarOpen, "写しにも出る")
    XCTAssertEqual(
      pane.bodyRect, NSRect(x: 37 + 241, y: 29, width: 900 - 278, height: 400 - 2 - 29),
      "レール・サイドバーの右、タブ行の下の hairline はその外側")

    let document = try tab.editor.open(try file("a.swift", "let a = 1\n"))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.bodyRect.minY, 29 + 20, "文書があればパンくずの分だけ下がる")
    XCTAssertEqual(document.surface.view.frame, pane.bodyRect)

    window.setContentSize(NSSize(width: 360 + FaceGeometry.spine, height: 400))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.shell.sidebarOpen, "狭い列でも隠れない")
    XCTAssertEqual(pane.shownSidebarWidth, 360 - 36 - 2 - 160, "本体に 160 残るまで表示幅を切り詰める")
    XCTAssertEqual(pane.bodyRect.minX, 37 + 162 + 1)
    XCTAssertEqual(pane.bodyRect.width, 160)
    XCTAssertEqual(pane.sidebar.width, 240, "記憶の幅は変えない")
    XCTAssertEqual(document.surface.view.frame, pane.bodyRect)

    // 切り詰め中のドラッグ。起点は描かれている境（162）で、記憶（240）ではない。
    let handle = try XCTUnwrap(pane.subviews.first { $0 is SidebarResizeHandle })
    XCTAssertEqual(handle.frame.minX, 37 + 162 - 2, "当たりは描かれている境に居る")
    handle.mouseDown(with: .mouse(.leftMouseDown, at: point(pane, 37 + 162), in: window))
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: point(pane, 37 + 162 + 40), in: window))
    XCTAssertEqual(pane.shownSidebarWidth, 162, "上限に押し付けても境は動かない")
    XCTAssertEqual(pane.sidebar.width, 240, "境が動かないドラッグは記憶に触れない")
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: point(pane, 37 + 162 - 2), in: window))
    XCTAssertEqual(pane.shownSidebarWidth, 160, "境はポインタに追従する（起点は 162）")
    XCTAssertEqual(pane.sidebar.width, 160, "境を動かせば記憶もそこへ")
    handle.mouseUp(with: .mouse(.leftMouseUp, at: point(pane, 37 + 160), in: window))
    pane.sidebar.setWidth(240)
    pane.sidebar.commit()

    window.setContentSize(NSSize(width: 340 + FaceGeometry.spine, height: 400))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.shownSidebarWidth, 142, "下限 160 を割って切り詰まる")
    handle.mouseDown(with: .mouse(.leftMouseDown, at: point(pane, 37 + 142), in: window))
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: point(pane, 37 + 142 - 50), in: window))
    XCTAssertEqual(pane.shownSidebarWidth, 142, "下限までも出せない列では動かない")
    XCTAssertEqual(pane.sidebar.width, 240, "動かないので記憶にも触れない")
    handle.mouseUp(with: .mouse(.leftMouseUp, at: point(pane, 37 + 92), in: window))

    window.setContentSize(NSSize(width: 120 + FaceGeometry.spine, height: 400))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.shownSidebarWidth, 0, "極端な幅では残りをそのまま分け、0 まで縮む")
    XCTAssertEqual(pane.bodyRect.minX, 37 + 1)

    window.setContentSize(NSSize(width: 900 + FaceGeometry.spine, height: 400))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.shownSidebarWidth, 240, "広がれば記憶の幅に戻る")
    XCTAssertEqual(pane.bodyRect.minX, 37 + 241)

    pane.shell.toggleSidebar()
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertFalse(pane.sidebar.isOpen, "レールの選択中の項目を押すと閉じる")
    XCTAssertFalse(pane.shell.sidebarOpen, "閉じている間はレールの選択印が無い")
    XCTAssertEqual(pane.bodyRect.minX, 37, "レールだけ残る")
    XCTAssertEqual(document.surface.view.frame, pane.bodyRect)

    pane.shell.toggleSidebar()
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.shell.sidebarOpen, "もう一度押すと開く")
    XCTAssertEqual(pane.bodyRect.minX, 37 + 241)
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
    let window = hosted(tab, width: 900)
    defer { window.orderOut(nil) }

    let handle = try XCTUnwrap(pane.subviews.first { $0 is SidebarResizeHandle })
    XCTAssertFalse(handle.isHidden)
    XCTAssertEqual(
      handle.frame, NSRect(x: 37 + 240 - 2, y: 0, width: 4, height: 398), "hairline を跨ぐ 4pt")
    let hit = pane.hitTest(pane.convert(NSPoint(x: 37 + 240, y: 200), to: pane.superview))
    XCTAssertTrue(hit === handle, "境は当たりが受ける")

    func point(_ x: CGFloat) -> NSPoint { self.point(pane, x) }
    handle.mouseDown(with: .mouse(.leftMouseDown, at: point(278), in: window))
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: point(278 + 60), in: window))
    XCTAssertEqual(state.width, 300, "引いた距離だけ広がる")
    XCTAssertEqual(pane.bodyRect.minX, 37 + 301, "その場で置き直す")
    XCTAssertEqual(handle.frame.minX, 37 + 300 - 2, "当たりも境に付いてくる")
    XCTAssertEqual(
      handle.trackingAreas.first?.options.contains([.cursorUpdate, .inVisibleRect]), true,
      "カーソルは可視矩形に追随する tracking area が出す（frame の移動で再登録が要らない）")
    try assertSidebarContentFills(pane, width: 300)
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: point(278 - 200), in: window))
    XCTAssertEqual(state.width, 160, "下限")
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: point(278 + 600), in: window))
    XCTAssertEqual(state.width, 900 - 36 - 2 - 160, "本体に 160 残るまで")
    handle.mouseUp(with: .mouse(.leftMouseUp, at: point(278 + 600), in: window))

    let otherWindow = hosted(other, width: 900)
    defer { otherWindow.orderOut(nil) }
    XCTAssertEqual(other.view.editor.bodyRect.minX, 37 + 702 + 1, "同じ状態を配られた面は同じ幅")
  }

  /// SwiftUI の中身（エクスプローラーの地と右の hairline）が pane の決めた幅を埋めているかを描画で見る。
  /// pane の矩形が動いても中身が固定幅のままなら、右の線が古い位置に残り、新しい境には地しか無い。
  private func assertSidebarContentFills(_ pane: EditorPaneView, width: CGFloat) throws {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))  // SwiftUI の描画コミット
    let rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
    pane.cacheDisplay(in: pane.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / pane.bounds.width
    let y = Int((pane.bounds.height - 12) * scale)  // ツリーの下の空き（根の行より下）
    func rgb(_ x: CGFloat) throws -> [Int] {
      let c = try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: y)?.usingColorSpace(.deviceRGB))
      return [c.redComponent, c.greenComponent, c.blueComponent].map { Int($0 * 255) }
    }
    func same(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 2 } }
    let ground = try rgb(37 + 60)
    let edge = 37 + width
    XCTAssertTrue(same(try rgb(edge - 2), ground), "境の手前まで地が続く")
    XCTAssertFalse(same(try rgb(edge + 0.5), ground), "境に hairline がある")
    XCTAssertTrue(same(try rgb(37 + 240 - 2), ground), "既定の幅 240 の位置には線が残らない")
    XCTAssertTrue(same(try rgb(37 + 240 + 0.5), ground))
  }

  /// 空状態でも骨（レール・サイドバー・タブ行）はクリックを自分で受け、本体だけが面自身に固定される。
  func testEmptyStateFixesOnlyTheBodyToThePane() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hosted(tab, width: 900)
    defer { window.orderOut(nil) }

    func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? {
      pane.hitTest(pane.convert(NSPoint(x: x, y: y), to: pane.superview))
    }
    XCTAssertTrue(hit(pane.bodyRect.midX, pane.bodyRect.midY) === pane, "本体は面自身")
    let rail = try XCTUnwrap(hit(18, 18))
    XCTAssertFalse(rail === pane, "レールは host が受ける")
    XCTAssertTrue(rail.isDescendant(of: pane))
    let tabs = try XCTUnwrap(hit(pane.bodyRect.midX, 14))
    XCTAssertFalse(tabs === pane, "タブ行の帯は host が受ける")
  }

  /// ツリーは pane が窓に付いて隠れていない間だけ握る——祖先（面の clip・タブの器）が隠れても降りる。
  func testTreeHoldsTheRootServiceOnlyWhileVisible() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    XCTAssertFalse(pane.tree.isLive, "窓に付く前は握らない")

    let window = hosted(tab, width: 900)
    defer { window.orderOut(nil) }
    XCTAssertTrue(pane.tree.isLive, "窓に付いて見えていれば握る")

    tab.setFaces(.terminalOnly, animated: false)
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.isHiddenOrHasHiddenAncestor, "前提: 幅 0 の面は隠れる")
    XCTAssertFalse(pane.tree.isLive, "面が隠れれば離す（祖先の hidden でも viewDidHide が届く）")

    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.tree.isLive, "戻れば握り直す")

    tab.view.isHidden = true
    XCTAssertFalse(pane.tree.isLive, "タブの器が隠れても離す")
    tab.view.isHidden = false
    XCTAssertTrue(pane.tree.isLive)

    tab.view.removeFromSuperview()
    XCTAssertFalse(pane.tree.isLive, "窓から外れれば離す")
  }

  /// cd で根が変われば新しい根のツリーになり、握っていたなら握り直す。
  func testChangingTheRootRebuildsTheTree() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hosted(tab, width: 900)
    defer { window.orderOut(nil) }
    let before = pane.tree
    XCTAssertEqual(before.root, GitWorktreeRoot.normalizedPath("/tmp"))

    let other = try XCTUnwrap(TestIsolation.caseDir).path
    tab.surface.currentPwd = other
    XCTAssertFalse(pane.tree === before, "作り直す")
    XCTAssertEqual(pane.tree.root, GitWorktreeRoot.root(of: other))
    XCTAssertTrue(pane.tree.isLive)
    XCTAssertFalse(before.isLive, "古いツリーは離す")

    tab.surface.currentPwd = other + "/"
    XCTAssertTrue(pane.tree.root == GitWorktreeRoot.root(of: other), "同じ根なら作り直さない")
  }

  /// 骨の写しはセッションに追従し、文書をアクティブにするとツリーがその行を選択する。
  func testShellMirrorsTheSessionAndRevealsTheActiveDocument() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hosted(tab, width: 900)
    defer { window.orderOut(nil) }

    let a = try tab.editor.open(try file("a.swift", "a"))
    let b = try tab.editor.open(try file("b.md", "b"))
    XCTAssertEqual(pane.shell.tabs.map(\.name), ["a.swift", "b.md"])
    XCTAssertEqual(pane.shell.activeName, "b.md")
    XCTAssertEqual(pane.tree.selected, "b.md", "アクティブにした文書の行を選択表示する")

    a.surface.responder.perform(Selector(("insertText:")), with: "Z")
    XCTAssertEqual(pane.shell.tabs.map(\.isDirty), [true, false], "同一文書の未保存の変化も写る")

    tab.editor.close(b)
    XCTAssertEqual(pane.shell.tabs.map(\.name), ["a.swift"])
    XCTAssertTrue(pane.document === a)
    XCTAssertEqual(pane.tree.selected, "a.swift")
  }
}
