import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 面の骨——骨の操作が pane に結線されてセッション・ツリー・焦点へ届き、行内入力は出すたびに作り直され、入力の状態が落ちれば
/// 終わり、骨の host はクリックを自分で受け、ツリーは面が窓に付いて隠れていない間だけ根のサービスを握り、cd で根が
/// 変わればツリーを作り直す（サイドバーの幅は `EditorPaneViewSidebarTests`）。
///
/// 壊れると何が起きるか。結線が外れると操作が無反応のまま緑。hitTest が面全体を self に固定したままだと骨が
/// クリックできない。隠れた連のツリーが握り続けると全連の根を常時監視する。
@MainActor
final class EditorPaneViewShellTests: OrbeTestCase {
  /// 行内入力を続けて出すと前の入力は消えて新しい入力だけが出る。入力の終わりは入力の状態が落ちることで、
  /// Esc・焦点の移動だけでなく、すべて折りたたむ・作成先を畳む・左の列を閉じる・cd でも落ち、入力欄に
  /// 居た焦点は面の行き先（文書のテキスト面）へ移る。
  func testInlineInputIsRecreatedPerRequestAndEndsWhenItsStateDrops() throws {
    let dir = TestScratch.caseDir
    let tab = TerminalTab.alone(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    let window = hostEditor(tab, width: 900)
    let document = try tab.group.editor.open(try caseFile("a.txt", "a"), as: .pinned)

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
    try endsWhenTheStateDrops("左の列を閉じる") { pane.toggleSidebar() }
    pane.toggleSidebar()
    try endsWhenTheStateDrops("すべて折りたたむ") { pane.shell.collapseAll() }
    let sub = dir.appendingPathComponent("d")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    pane.tree.toggle("d")
    pane.shell.createFile()
    XCTAssertEqual(pane.tree.newEntry?.directory, "d", "前提: 挿し先は d")
    try endsWhenTheStateDrops("作成先のディレクトリを畳む") { pane.tree.toggle("d") }
    let other = dir.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try endsWhenTheStateDrops("cd") { tab.group.rekey(GitWorktreeRoot.root(of: other.path)) }
  }

  /// 骨の操作（上のバーの画面の切り替え・上のバーの左の列の開閉・新規ファイル・ツリーの行・開いている文書の切り替え・
  /// すべて折りたたむ・行内入力の確定）は pane に結線され、セッション・ツリー・焦点へ届く。閉包はどれも既定値持ちなので、
  /// 結線が 1 本外れてもコンパイルは通り、操作が無反応のまま緑になる——それをここで固定する。
  func testShellActionsReachTheSessionTreeAndFocus() throws {
    let dir = TestScratch.caseDir
    let sub = dir.appendingPathComponent("d")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let a = try caseFile("a.swift", "a")
    let b = try caseFile("b.md", "b")
    let tab = TerminalTab.alone(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    let window = hostEditor(tab, width: 900)
    window.makeFirstResponder(nil)

    pane.shell.createFile()
    XCTAssertTrue(window.firstResponder === pane)
    XCTAssertEqual(pane.tree.newEntry?.directory, "")

    pane.shell.open(a, .preview)
    XCTAssertEqual(pane.document?.url.lastPathComponent, "a.swift", "ツリーの行で開く")
    XCTAssertTrue(tab.group.editor.preview === pane.document, "ツリーの行の 1 回目は仮の文書")
    XCTAssertTrue(window.firstResponder === pane.document?.surface.responder, "焦点はテキスト面へ")
    pane.shell.open(a, .pinned)
    XCTAssertNil(tab.group.editor.preview, "2 回目（ダブルクリック）で普通の文書")
    pane.shell.open(b, .preview)
    window.makeFirstResponder(nil)
    pane.activate(a)
    XCTAssertEqual(pane.document?.url.lastPathComponent, "a.swift", "開いている文書を切り替える")
    XCTAssertTrue(window.firstResponder === pane.document?.surface.responder, "切り替えても焦点はテキスト面へ")

    pane.tree.toggle("d")
    XCTAssertEqual(pane.tree.expanded, ["d"], "ツリーのディレクトリが開く")
    pane.shell.createFile()
    XCTAssertEqual(pane.tree.newEntry?.directory, "d", "選択したディレクトリに挿す")
    pane.tree.setNewName("x.swift")
    XCTAssertTrue(pane.tree.commitNew())
    XCTAssertEqual(pane.document?.url.lastPathComponent, "x.swift", "作ったファイルは pane 経由で開く")

    pane.shell.collapseAll()
    XCTAssertTrue(pane.tree.expanded.isEmpty)

    pane.shell.selectScreen(.changes)
    XCTAssertEqual(tab.group.editor.screen, .changes, "上のバーの切り替えで画面を選ぶ")
    pane.shell.toggleSidebar()
    XCTAssertFalse(pane.sidebar.isOpen, "上のバーの左端で左の列を閉じる")
  }

  /// 空状態でも骨（上のバー・左の列）はクリックを自分で受け、本体だけが面自身に固定される。
  func testEmptyStateFixesOnlyTheBodyToThePane() throws {
    let tab = TerminalTab.alone(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    hostEditor(tab, width: 900)

    func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? {
      pane.hitTest(pane.convert(NSPoint(x: x, y: y), to: pane.superview))
    }
    XCTAssertTrue(hit(pane.bodyRect.midX, pane.bodyRect.midY) === pane, "本体は面自身")
    let bar = try XCTUnwrap(hit(18, 18))
    XCTAssertTrue(bar.isDescendant(of: pane.barHost), "上のバーは host が受ける")
    let side = try XCTUnwrap(hit(60, 200))
    XCTAssertTrue(side.isDescendant(of: pane.sideHost), "左の列は host が受ける")
  }

  /// ツリーとプロジェクト検索は pane が窓に付いて隠れていない間だけ根のサービスを握る——祖先（面の clip・連の器）が隠れても
  /// 降りる。
  func testTreeAndProjectSearchHoldTheRootServiceOnlyWhileVisible() throws {
    let tab = TerminalTab.alone(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    XCTAssertFalse(pane.tree.isLive, "窓に付く前は握らない")
    XCTAssertFalse(pane.projectSearch.isLive)

    hostEditor(tab, width: 900)
    XCTAssertTrue(pane.tree.isLive, "窓に付いて見えていれば握る")
    XCTAssertTrue(pane.projectSearch.isLive)

    tab.group.view.show(.terminal, animated: false)
    tab.group.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.isHiddenOrHasHiddenAncestor, "前提: 閉じた面は隠れる")
    XCTAssertFalse(pane.tree.isLive, "面が隠れれば離す（祖先の hidden でも viewDidHide が届く）")
    XCTAssertFalse(pane.projectSearch.isLive)

    tab.group.view.show(.editor, animated: false)
    tab.group.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.tree.isLive, "戻れば握り直す")
    XCTAssertTrue(pane.projectSearch.isLive)

    tab.group.view.isHidden = true
    XCTAssertFalse(pane.tree.isLive, "連の器が隠れても離す")
    XCTAssertFalse(pane.projectSearch.isLive)
    tab.group.view.isHidden = false
    XCTAssertTrue(pane.tree.isLive)
    XCTAssertTrue(pane.projectSearch.isLive)

    tab.group.view.removeFromSuperview()
    XCTAssertFalse(pane.tree.isLive, "窓から外れれば離す")
    XCTAssertFalse(pane.projectSearch.isLive)
  }

  /// 連の根が変われば（cd）新しい根のツリーになり、握っていたなら握り直す。
  func testChangingTheRootRebuildsTheTree() throws {
    let tab = TerminalTab.alone(cwd: "/tmp", editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    hostEditor(tab, width: 900)
    let before = pane.tree
    XCTAssertEqual(before.root, GitWorktreeRoot.normalizedPath("/tmp"))

    let other = TestScratch.caseDir.path
    tab.group.rekey(GitWorktreeRoot.root(of: other))
    XCTAssertFalse(pane.tree === before, "作り直す")
    XCTAssertEqual(pane.tree.root, GitWorktreeRoot.root(of: other))
    XCTAssertTrue(pane.tree.isLive)
    XCTAssertFalse(before.isLive, "古いツリーは離す")
  }

  /// 文書をアクティブにするとツリーがその行を選択する。
  func testShellMirrorsTheSessionAndRevealsTheActiveDocument() throws {
    let dir = TestScratch.caseDir
    let tab = TerminalTab.alone(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    hostEditor(tab, width: 900)

    let a = try tab.group.editor.open(try caseFile("a.swift", "a"), as: .pinned)
    let b = try tab.group.editor.open(try caseFile("b.md", "b"), as: .pinned)
    XCTAssertEqual(pane.tree.selected, "b.md", "アクティブにした文書の行を選択表示する")

    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("docs"), withIntermediateDirectories: true)
    pane.tree.toggle("docs")
    XCTAssertEqual(pane.tree.selected, "docs")
    pane.shell.open(b.url, .preview)
    XCTAssertEqual(pane.tree.selected, "b.md", "既に焦点の文書の行を押しても選択はそこへ移る")
    pane.tree.toggle("docs")
    pane.activate(b.url)
    XCTAssertEqual(pane.tree.selected, "b.md", "既に焦点の文書へ切り替えても同じ")

    tab.group.editor.close(b)
    XCTAssertTrue(pane.document === a)
    XCTAssertEqual(pane.tree.selected, "a.swift")
  }
}
