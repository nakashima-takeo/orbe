import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 連の永続状態とエディター——開いている文書と仮のタブはそのまま書き、復元した状態は器が初めて載るとき（`materialize`）に
/// 消費して開き（仮のタブは仮のまま）、未消費のまま保存すれば同じ形で書き戻す。検索の問いは復元で入力欄に戻り（探さない）、
/// 変えれば書き戻す。復元した連は選んでいた画面で開き、選んでいない連は根で決まる画面で開く。制御 API の `open_file` は
/// 普通のタブで開く。cd で連が畳まれるときは、文書を行き先へ移す（`absorb`）か根を付け替える（`rekey`。前の根の diff は
/// 残さない）。
///
/// 壊れると何が起きるか。一度も見なかった連の文書が終了で失われる。復元で読めないファイルが復元を止める。再起動で
/// 仮のタブが普通のタブとして積もる。エージェントが見せたファイルを人の次のクリックが黙って入れ替える。再起動で
/// 連の検索語と切替が消える、復元のたびに根の全体を探す。cd で連を移ったタブの文書が消える、未保存の編集が黙って上書きされる、
/// 移った文書が外の書き換えを見失って ⌘S がエージェントの編集を潰す。再起動で選んでいた画面が戻らない。diff が自動で開いた
/// だけで Changes を選んだことになり、git 管理外へ cd しても Changes の空の本体で開く。cd した後も前の worktree の diff が
/// 本体に出る。
@MainActor
final class TabGroupTests: OrbeTestCase {
  private func file(_ name: String) throws -> URL {
    let url = TestScratch.caseDir.appendingPathComponent(name)
    try Data("x".utf8).write(to: url)
    return url.resolvingSymlinksInPath()
  }

  private func group(_ state: GroupState? = nil) -> TabGroup {
    TabGroup(key: "/tmp", state: state?.editor, editorSurfaces: EditorSurfaces(queriesRoot: nil))
  }

  func testGroupStateCarriesOpenDocumentsAndTheActive() throws {
    let group = group()
    XCTAssertNil(group.groupState(), "文書も問いも無ければ書かない")
    let a = try group.editor.open(try file("a.txt"), as: .pinned)
    let b = try group.editor.open(try file("b.txt"), as: .preview)
    group.editor.activate(a)
    XCTAssertEqual(
      group.groupState(),
      GroupState(
        root: "/tmp",
        editor: EditorState(
          documents: .init(open: [a.url.path, b.url.path], active: a.url.path, preview: b.url.path))
      ))
  }

  /// `open_file` は普通のタブで開き、仮のタブで開いているファイルなら普通のタブに変える。
  func testOpenFileOpensAPinnedTab() throws {
    let group = group()
    try group.openFile(try file("a.txt"))
    XCTAssertNil(group.editor.preview)
    let b = try group.editor.open(try file("b.txt"), as: .preview)
    try group.openFile(b.url)
    XCTAssertNil(group.editor.preview, "仮のタブは普通に変わる")
  }

  func testRestoredStateIsKeptUntilMaterializationAndThenOpened() throws {
    let a = try file("a.txt")
    let state = GroupState(
      root: "/tmp",
      editor: EditorState(
        documents: .init(open: [a.path, "/nonexistent/z.txt"], active: a.path, preview: a.path)))
    let group = group(state)
    XCTAssertTrue(group.editor.documents.isEmpty, "復元時は開かない")
    XCTAssertEqual(group.groupState(), state, "未消費のまま同じ形で書き戻す")

    var changes = 0
    group.onEditorChange = { changes += 1 }
    group.materialize()
    XCTAssertEqual(group.editor.documents.map(\.url), [a], "読めないパスは黙って落ちる")
    XCTAssertEqual(group.editor.activeDocument?.url, a)
    XCTAssertEqual(group.editor.preview?.url, a, "仮のタブは仮のまま戻る")
    XCTAssertEqual(changes, 1)
    XCTAssertEqual(
      group.groupState()?.editor,
      EditorState(documents: .init(open: [a.path], active: a.path, preview: a.path)),
      "以後は開いている文書を書く")

    group.editor.close(try XCTUnwrap(group.editor.activeDocument))
    group.materialize()
    XCTAssertNil(group.groupState(), "全部閉じれば消費済みの状態は戻らない（2 度目の materialize も何もしない）")
  }

  func testTheSearchQueryIsRestoredWithoutSearchingAndWrittenBack() throws {
    let query = SearchQuery(pattern: "needle", wholeWord: true)
    let group = group(GroupState(root: "/tmp", editor: EditorState(search: query)))
    let search = group.view.editor.projectSearch
    XCTAssertEqual(search.query, query, "入力欄に戻る")
    XCTAssertEqual(search.phase, .idle, "復元では探さない")
    XCTAssertEqual(group.groupState()?.editor, EditorState(search: query))

    var changes = 0
    group.onEditorChange = { changes += 1 }
    search.toggle(.matchCase)
    XCTAssertEqual(changes, 1, "問いの変化は保存のきっかけ")
    XCTAssertEqual(
      group.groupState()?.editor.search,
      SearchQuery(pattern: "needle", matchCase: true, wholeWord: true))
  }

  /// 復元した連は選んでいた画面で開く。画面を選んでいない連は、根が git の worktree の根なら Changes、そうでなければ Files で
  /// 開く。
  func testARestoredGroupOpensOnTheChosenScreenOrOnTheOneItsRootDecides() throws {
    let root = GitWorktreeRoot.root(of: try TempGitRepo().root)
    let surfaces = EditorSurfaces(queriesRoot: nil)
    XCTAssertEqual(TabGroup(key: root, editorSurfaces: surfaces).editor.screen, .changes)
    XCTAssertEqual(
      TabGroup(key: TestScratch.caseDir.path, editorSurfaces: surfaces).editor.screen, .files)
    let restored = TabGroup(key: root, state: EditorState(screen: .files), editorSurfaces: surfaces)
    XCTAssertEqual(restored.editor.screen, .files)
  }

  // MARK: - cd で連が畳まれる

  /// Changes の diff が自動で開いただけの連は画面を選んだことにならない——最後のタブが git 管理外のフォルダへ cd して根が
  /// 付け替わると、Files で開き、前の根の Changes の diff は残らない。
  func testAGroupWhoseChangesDiffOnlyOpenedByItselfOpensOnFilesOutsideGit() throws {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900)
    addTeardownBlock { window.orderOut(nil) }
    let pane = tab.group.view.editor
    pumpMain(until: { pane.diff != nil }, "前提: Changes の diff が自動で開く")
    XCTAssertNil(tab.group.groupState(), "画面を選んでいないので、書くものが無い")

    tab.group.rekey(TestScratch.caseDir.path)
    XCTAssertEqual(tab.group.editor.screen, .files)
    tab.group.editor.selectScreen(.changes)
    XCTAssertNil(pane.diff, "前の根の diff は残らない")
  }

  /// 連の最後のタブが行き先の無い根へ移ると、連ごとキーとエディター面の根が付け替わる（文書はそのまま）。
  func testRekeyMovesTheKeyAndTheEditorRoot() throws {
    let group = group()
    let a = try group.editor.open(try file("a.txt"), as: .pinned)
    let next = TestScratch.caseDir.path
    group.rekey(next)
    XCTAssertEqual(group.key, next)
    XCTAssertEqual(group.view.editor.tree.root, next)
    XCTAssertEqual(group.groupState()?.root, next)
    XCTAssertTrue(group.editor.activeDocument === a)
  }

  /// 畳まれる連の文書は行き先の列の末尾へ移り、行き先の焦点は保たれる。同じ実ファイルのタブは行き先の 1 枚にまとまる——元の
  /// 文書だけが未保存なら元の文書がその位置に入り、行き先の焦点がその文書だったなら焦点も入れ替わる。元の連は空になる。
  func testAbsorbAppendsDocumentsAndKeepsTheDestinationsActive() throws {
    let dest = group()
    let from = group()
    let shared = try file("shared.txt")
    let a = try dest.editor.open(try file("a.txt"), as: .pinned)
    _ = try dest.editor.open(shared, as: .pinned)
    let edited = try from.editor.open(shared, as: .pinned)
    edited.surface.responder.perform(Selector(("insertText:")), with: "y")
    let b = try from.editor.open(try file("b.txt"), as: .pinned)
    var changes = 0
    dest.onEditorChange = { changes += 1 }

    dest.absorb(from)

    XCTAssertEqual(dest.editor.documents.map(\.url), [a.url, shared, b.url])
    XCTAssertTrue(dest.editor.documents[1] === edited, "元だけが未保存なら元の文書が入る")
    XCTAssertTrue(dest.editor.activeDocument === edited, "行き先の焦点の位置を保ち、入れ替わった文書が焦点")
    XCTAssertTrue(from.editor.documents.isEmpty)
    XCTAssertEqual(changes, 1, "変化は 1 本の通知")
    XCTAssertTrue(dest.view.editor.document === edited, "行き先の面は自分の焦点の文書を見せる")
    XCTAssertNil(from.view.editor.document, "元の面は文書を手放す")
  }

  /// 両方で未保存なら行き先の文書が残る。
  func testAbsorbKeepsTheDestinationWhenBothAreDirty() throws {
    let dest = group()
    let from = group()
    let shared = try file("shared.txt")
    let mine = try dest.editor.open(shared, as: .pinned)
    mine.surface.responder.perform(Selector(("insertText:")), with: "m")
    let theirs = try from.editor.open(shared, as: .pinned)
    theirs.surface.responder.perform(Selector(("insertText:")), with: "t")

    dest.absorb(from)

    XCTAssertEqual(dest.editor.documents.count, 1)
    XCTAssertTrue(dest.editor.documents[0] === mine)
  }

  /// 行き先が空なら元の焦点を引き継ぐ。仮のタブは、行き先に仮が無ければ仮のまま移る。
  func testAbsorbIntoAnEmptyGroupTakesTheActiveAndThePreview() throws {
    let dest = group()
    let from = group()
    let a = try from.editor.open(try file("a.txt"), as: .pinned)
    let p = try from.editor.open(try file("p.txt"), as: .preview)
    from.editor.activate(a)

    dest.absorb(from)

    XCTAssertTrue(dest.editor.activeDocument === a)
    XCTAssertTrue(dest.editor.preview === p)
  }

  /// 行き先の仮のタブの文書が元の未保存の文書に替われば、仮でなくなる——次に仮で開いたファイルが入れ替えで黙って捨てない。
  func testAbsorbPinsTheTemporaryTabThatTakesOverAnUnsavedDocument() throws {
    let dest = group()
    let from = group()
    let url = try file("a.txt")
    _ = try dest.editor.open(url, as: .preview)
    let edited = try from.editor.open(url, as: .pinned)
    edited.surface.responder.perform(Selector(("insertText:")), with: "y")

    dest.absorb(from)
    _ = try dest.editor.open(try file("b.txt"), as: .preview)

    XCTAssertTrue(dest.editor.documents.contains { $0 === edited })
  }

  /// 移った文書は外のファイルに付いていき続ける——未保存のまま外で書き換えられれば印が立ち、その変化は行き先の連の
  /// 通知に載る。
  func testAbsorbedDocumentKeepsFollowingItsFile() throws {
    let dest = group()
    let from = group()
    let url = try file("a.txt")
    let moved = try from.editor.open(url, as: .pinned)
    moved.surface.responder.perform(Selector(("insertText:")), with: "mine ")
    dest.absorb(from)
    var changes = 0
    dest.onEditorChange = { changes += 1 }

    try Data("theirs".utf8).write(to: url)

    pumpMain(until: { moved.isDiskChanged }, "未保存なら印が立つ")
    XCTAssertEqual(changes, 1, "印の変化は行き先の連の通知に載る")
  }

  /// 一度も載らなかった元の連の復元待ちは、行き先が載っていれば開き、まだなら行き先の復元待ちの末尾へ合わさる。
  func testAbsorbCarriesThePendingDocuments() throws {
    let a = try file("a.txt")
    let b = try file("b.txt")
    let pending = { (path: String) in
      GroupState(
        root: "/tmp", editor: EditorState(documents: .init(open: [path], active: path)))
    }
    let waiting = group(pending(a.path))
    waiting.absorb(group(pending(b.path)))
    XCTAssertEqual(
      waiting.groupState()?.editor.documents,
      .init(open: [a.path, b.path], active: a.path), "まだ載っていない行き先は復元待ちに合わせる")

    let shown = group()
    shown.materialize()
    shown.absorb(group(pending(b.path)))
    XCTAssertEqual(shown.editor.documents.map(\.url), [b], "載っている行き先はその場で開く")
  }

  /// まだ一度も載っていない連へ cd で文書が移ってきても、その連の復元待ちは保存から消えない——開いている文書が先で、
  /// 復元待ちにしか無い文書を末尾へ合わせて書く。
  func testAbsorbIntoAGroupNotYetShownKeepsItsPendingDocumentsInTheState() throws {
    let a = try file("a.txt")
    let waiting = group(
      GroupState(
        root: "/tmp", editor: EditorState(documents: .init(open: [a.path], active: a.path))))
    let from = group()
    let b = try from.editor.open(try file("b.txt"), as: .pinned)

    waiting.absorb(from)

    XCTAssertEqual(
      waiting.groupState()?.editor.documents,
      .init(open: [b.url.path, a.path], active: b.url.path))
  }
}
