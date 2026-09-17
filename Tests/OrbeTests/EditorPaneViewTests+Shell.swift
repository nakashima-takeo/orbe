import AppKit
import XCTest

@testable import Orbe

/// 面の骨——pane が幾何を解き（レール｜サイドバー（≥720）｜列の頭｜本体）、骨の host はクリックを自分で
/// 受け、ツリーは面が窓に付いて隠れていない間だけ根のサービスを握り、cd で根が変わればツリーを作り直す。
///
/// 壊れると何が起きるか。hitTest が面全体を self に固定したままだと骨がクリックできない。隠れたタブの
/// ツリーが握り続けると全タブの根を常時監視する。狭い面でサイドバーが畳まれないと本体が潰れる。
@MainActor
final class EditorPaneViewShellTests: OrbeTestCase {
  private func file(_ name: String, _ text: String) throws -> URL {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
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

  func testWideFaceShowsTheSidebarAndNarrowFaceFoldsIt() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hosted(tab, width: 900)
    defer { window.orderOut(nil) }

    XCTAssertTrue(pane.sidebarVisible)
    XCTAssertTrue(pane.shell.sidebarVisible, "写しにも出る")
    XCTAssertEqual(
      pane.bodyRect, NSRect(x: 52 + 272, y: 34, width: 900 - 324, height: 400 - 2 - 34))

    let document = try tab.editor.open(try file("a.swift", "let a = 1\n"))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.bodyRect.minY, 34 + 22, "文書があればパンくずの分だけ下がる")
    XCTAssertEqual(document.surface.view.frame, pane.bodyRect)

    window.setContentSize(NSSize(width: 640 + FaceGeometry.spine, height: 400))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertFalse(pane.sidebarVisible, "720 未満ではサイドバーを畳む")
    XCTAssertFalse(pane.shell.sidebarVisible)
    XCTAssertEqual(pane.bodyRect.minX, 52, "レールだけ残る")
    XCTAssertEqual(document.surface.view.frame, pane.bodyRect)
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
    let rail = try XCTUnwrap(hit(26, 26))
    XCTAssertFalse(rail === pane, "レールは host が受ける")
    XCTAssertTrue(rail.isDescendant(of: pane))
    let tabs = try XCTUnwrap(hit(pane.bodyRect.midX, 17))
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
