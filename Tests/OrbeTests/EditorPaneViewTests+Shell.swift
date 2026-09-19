import AppKit
import XCTest

@testable import Orbe

/// 面の骨——骨の操作が pane に結線されてセッション・ツリー・焦点へ届き、行内入力は出すたびに作り直され、入力の状態が落ちれば
/// 終わり、骨の host はクリックを自分で受け、ツリーは面が窓に付いて隠れていない間だけ根のサービスを握り、cd で根が
/// 変わればツリーを作り直す（サイドバーの幅は `EditorPaneViewSidebarTests`）。
///
/// 壊れると何が起きるか。結線が外れると操作が無反応のまま緑。hitTest が面全体を self に固定したままだと骨が
/// クリックできない。隠れたタブのツリーが握り続けると全タブの根を常時監視する。
@MainActor
final class EditorPaneViewShellTests: OrbeTestCase {
  /// 行内入力を続けて出すと前の入力は消えて新しい入力だけが出る。入力の終わりは入力の状態が落ちることで、
  /// Esc・焦点の移動だけでなく、すべて折りたたむ・根を畳む・作成先を畳む・レールで閉じる・cd でも落ち、入力欄に
  /// 居た焦点は面の行き先（文書のテキスト面）へ移る。
  func testInlineInputIsRecreatedPerRequestAndEndsWhenItsStateDrops() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }
    let document = try tab.editor.open(try caseFile("a.txt", "a"))

    pane.shell.createFile()
    XCTAssertTrue(window.firstResponder === pane, "入力を出す前に面自身が焦点を取る")
    let first = try XCTUnwrap(pane.tree.newEntry)
    pane.tree.setNewName("draft")
    pane.shell.createDirectory()
    let second = try XCTUnwrap(pane.tree.newEntry)
    XCTAssertNotEqual(first.generation, second.generation)
    XCTAssertTrue(second.isDirectory)
    XCTAssertEqual(second.name, "", "新しい入力は空の名前から")
    pane.tree.cancelNew(first.generation)
    XCTAssertNotNil(pane.tree.newEntry, "古い入力の取り消し（blur）は今の入力に触れない")

    func endsWhenTheStateDrops(_ how: String, _ transition: () throws -> Void) throws {
      if pane.tree.newEntry == nil { pane.shell.createFile() }
      let before = pane.tree
      let generation = try XCTUnwrap(before.newEntry).generation
      _ = try inputField(pane, in: window)  // 前提: 入力欄が焦点を持っている
      try transition()
      pumpMain(
        until: { before.newEntry?.generation != generation }, timeout: 5,
        "\(how): 入力の状態が落ちる")
      pumpMain(
        until: { window.firstResponder === document.surface.responder }, timeout: 5,
        "\(how): 入力欄に居た焦点は面の行き先へ")
    }
    try endsWhenTheStateDrops("レールで閉じる") { pane.shell.toggleSidebar() }
    pane.shell.toggleSidebar()
    try endsWhenTheStateDrops("根を畳む") { pane.tree.isRootOpen = false }
    pane.tree.isRootOpen = true
    try endsWhenTheStateDrops("すべて折りたたむ") { pane.shell.collapseAll() }
    let sub = dir.appendingPathComponent("d")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    pane.shell.revealDirectory(sub)
    pane.shell.createFile()
    XCTAssertEqual(pane.tree.newEntry?.directory, "d", "前提: 挿し先は d")
    try endsWhenTheStateDrops("作成先のディレクトリを畳む") { pane.tree.toggle("d") }
    let other = dir.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try endsWhenTheStateDrops("cd") { tab.surface.currentPwd = other.path }
  }

  /// 骨の操作（新規ファイル・ツリーの行・ファイルタブ・パンくず・すべて折りたたむ・行内入力の確定）は pane に
  /// 結線され、セッション・ツリー・焦点へ届く。閉包はどれも既定値持ちなので、結線が 1 本外れても
  /// コンパイルは通り、操作が無反応のまま緑になる——それをここで固定する。
  func testShellActionsReachTheSessionTreeAndFocus() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let sub = dir.appendingPathComponent("d")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let a = try caseFile("a.swift", "a")
    let b = try caseFile("b.md", "b")
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }
    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    tab.view.layoutSubtreeIfNeeded()
    window.makeFirstResponder(nil)

    pane.shell.createFile()
    XCTAssertEqual(tab.faces.focus, .editor, "行内入力を出す前に面の記憶がエディターへ移る")
    XCTAssertTrue(window.firstResponder === pane)
    XCTAssertEqual(pane.tree.newEntry?.directory, "")

    pane.shell.open(a)
    XCTAssertEqual(pane.document?.url.lastPathComponent, "a.swift", "ツリーの行で開く")
    XCTAssertTrue(window.firstResponder === pane.document?.surface.responder, "焦点はテキスト面へ")
    pane.shell.open(b)
    window.makeFirstResponder(nil)
    pane.shell.activate(a)
    XCTAssertEqual(pane.document?.url.lastPathComponent, "a.swift", "ファイルタブで切り替える")
    XCTAssertTrue(window.firstResponder === pane.document?.surface.responder, "切り替えても焦点はテキスト面へ")

    pane.shell.revealDirectory(sub)
    XCTAssertEqual(pane.tree.expanded, ["d"], "パンくずのディレクトリが開く")
    pane.shell.createFile()
    XCTAssertEqual(pane.tree.newEntry?.directory, "d", "選択したディレクトリに挿す")
    pane.tree.setNewName("x.swift")
    XCTAssertTrue(pane.tree.commitNew())
    XCTAssertEqual(pane.document?.url.lastPathComponent, "x.swift", "作ったファイルは pane 経由で開く")

    pane.shell.collapseAll()
    XCTAssertTrue(pane.tree.expanded.isEmpty)
  }

  /// 空状態でも骨（レール・サイドバー・タブ行）はクリックを自分で受け、本体だけが面自身に固定される。
  func testEmptyStateFixesOnlyTheBodyToThePane() throws {
    let tab = TerminalTab(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
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

    let window = hostEditor(tab, width: 900)
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
    let window = hostEditor(tab, width: 900)
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
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }

    let a = try tab.editor.open(try caseFile("a.swift", "a"))
    let b = try tab.editor.open(try caseFile("b.md", "b"))
    XCTAssertEqual(pane.shell.tabs.map(\.name), ["a.swift", "b.md"])
    XCTAssertEqual(pane.shell.activeName, "b.md")
    XCTAssertEqual(pane.tree.selected, "b.md", "アクティブにした文書の行を選択表示する")

    a.surface.responder.perform(Selector(("insertText:")), with: "Z")
    XCTAssertEqual(pane.shell.tabs.map(\.isDirty), [true, false], "同一文書の未保存の変化も写る")

    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("docs"), withIntermediateDirectories: true)
    pane.tree.toggle("docs")
    XCTAssertEqual(pane.tree.selected, "docs")
    pane.shell.open(b.url)
    XCTAssertEqual(pane.tree.selected, "b.md", "既に焦点の文書の行を押しても選択はそこへ移る")
    pane.tree.toggle("docs")
    pane.shell.activate(b.url)
    XCTAssertEqual(pane.tree.selected, "b.md", "既に焦点の文書のファイルタブでも同じ")

    tab.editor.close(b)
    XCTAssertEqual(pane.shell.tabs.map(\.name), ["a.swift"])
    XCTAssertTrue(pane.document === a)
    XCTAssertEqual(pane.tree.selected, "a.swift")
  }
}
