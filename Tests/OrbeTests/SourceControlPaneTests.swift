import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// エディター面に結んだソース管理パネル——行は区分に合った diff を仮のタブで開き、追跡中のファイルの破棄は確かめてから行い、
/// メッセージ欄の ⌘↵ はコミットだけを起こし、欄の中身が外から変わったら取り消しの履歴を捨て、取り消しはその欄の中で閉じる。
/// パネルを出していなくても面が見えていれば件数は status に追いつき（行とグラフは作らない）、cd した後の列は新しい根の行を
/// 出して押せば新しい根の diff を開く。行の ＋ を同じ位置で続けて押すと、次の行が次々にステージされる。
///
/// 壊れると何が起きるか。「ステージされている変更」の行で作業ツリーの diff が開き、コミットする中身と違うものを見て確かめた
/// ことになる。追跡中のファイルの編集が確認なしに消え、戻せない。ボタンが「同期」の間に欄で ⌘↵ を打つと、キー 1 つで
/// push が走る。コミットの後の ⌘Z が例外を投げ、欄の取り消しが壊れたまま残る。エクスプローラーを出している間、レールの
/// 件数が古い数で止まる・隠れたパネルのために git を読む。cd した後も列が前の根の行を出し、押した行やボタンが前の
/// worktree の diff を開く・前の worktree でステージや破棄をする。cd した・パネルを閉じた後の ⌘Z が、見えない欄の打鍵を
/// 戻して前の worktree の打ちかけのメッセージや別の窓の打ち足しを黙って消す。＋ を続けて押すと、ステージ済みの区分が
/// 現れて行がずれ、意図しない行をステージする。
@MainActor
final class SourceControlPaneTests: OrbeTestCase {
  struct Hosted {
    let repo: TempGitRepo
    let tab: TerminalTab
    let pane: EditorPaneView
    let window: NSWindow
    @MainActor var scm: ScmPanel { pane.scm }
  }

  /// 根 `repo` の連の面だけを窓に載せ、ソース管理パネルを出す（`showsPanel` が false ならサイドバーは既定のエクスプローラー）。
  func host(_ repo: TempGitRepo, showsPanel: Bool = true) -> Hosted {
    let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = pane
    pane.layoutSubtreeIfNeeded()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    if showsPanel { pane.shell.selectPanel(.sourceControl) }
    return Hosted(repo: repo, tab: tab, pane: pane, window: window)
  }

  func row(_ hosted: Hosted, _ section: ScmSection, _ path: String) throws -> Int {
    try XCTUnwrap(hosted.scm.layout.index[ScmRowID(section: section, path: path)])
  }

  /// 「ステージされている変更」の行はステージ済みの diff を、「変更」の行は作業ツリーの diff を、同じ仮のタブで開く。
  func testRowsOpenTheDiffOfTheirSectionInThePreviewTab() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "staged\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    pumpMain(
      until: { hosted.scm.changes.staged.count == 1 && hosted.scm.changes.changes.count == 1 },
      "両方の区分に a.txt")
    let editor = hosted.tab.group.editor

    hosted.scm.click(try row(hosted, .staged, "a.txt"), in: hosted.scm.layout)
    let staged = EditorTab.Key.diff(EditorDiff.Key(root: repo.root, path: "a.txt", kind: .staged))
    XCTAssertEqual(editor.activeID, staged)
    XCTAssertEqual(editor.previewID, staged)

    hosted.scm.click(try row(hosted, .changes, "a.txt"), in: hosted.scm.layout)
    let working = EditorTab.Key.diff(
      EditorDiff.Key(root: repo.root, path: "a.txt", kind: .workingTree))
    XCTAssertEqual(editor.activeID, working)
    XCTAssertEqual(editor.previewID, working)
    XCTAssertEqual(editor.tabs.map(\.id), [working], "仮のタブを入れ替える")
  }

  /// 未追跡だけの破棄は確かめずにゴミ箱へ移す。追跡中のファイルの破棄は確認のシートを出し、「破棄」を押すまで作業ツリーに
  /// 触らない。
  func testDiscardingTrackedChangesWaitsForTheConfirmation() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    try repo.write("n.txt", "new\n")
    let hosted = host(repo)
    pumpMain(until: { hosted.scm.changes.changes.count == 2 }, "変更の行")
    let untracked = repo.dir.appendingPathComponent("n.txt").path

    hosted.scm.press(try row(hosted, .changes, "n.txt"), .discard, in: hosted.scm.layout)
    XCTAssertNil(hosted.window.attachedSheet, "未追跡だけなら確かめない")
    pumpMain(
      until: {
        hosted.scm.control.operations.isEmpty && !FileManager.default.fileExists(atPath: untracked)
      },
      "ゴミ箱へ")

    hosted.scm.press(try row(hosted, .changes, "a.txt"), .discard, in: hosted.scm.layout)
    let sheet = try XCTUnwrap(hosted.window.attachedSheet, "追跡中なら確かめる")
    XCTAssertTrue(hosted.scm.control.operations.isEmpty, "確かめるまで捨て始めない")
    hosted.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    pumpMain(
      until: { (try? String(contentsOf: repo.url("a.txt"), encoding: .utf8)) == "one\n" },
      "破棄を押すと index の版へ戻る")
  }

  /// ソース管理を開くとメッセージ欄に焦点が入る。欄の ⌘↵ はコミットだけ——ボタンが「同期」でもネット操作を起こさず、
  /// コミットできるときはコミットする。
  func testCommandReturnInTheMessageOnlyCommits() throws {
    let repo = try TempGitRepo()
    repo.addOrigin()
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "unpushed"]).isSuccess)
    let origin = repo.git(["rev-parse", "origin/main"]).stdoutText
    let hosted = host(repo)
    let scm = hosted.scm
    pumpMain(until: { scm.focusedArea == .message }, "メッセージ欄に焦点")
    pumpMain(
      until: { scm.commitState.primary == .sync(GitStatus.Divergence(ahead: 1, behind: 0)) },
      "前提: ボタンが同期")
    let commandReturn = NSEvent.key("\r")

    scm.control.message = "typed"
    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: commandReturn))
    XCTAssertTrue(scm.control.operations.isEmpty, "何も始めない")
    XCTAssertEqual(repo.git(["rev-parse", "origin/main"]).stdoutText, origin)

    try repo.write("c.txt", "c\n")
    XCTAssertTrue(repo.git(["add", "c.txt"]).isSuccess)
    pumpMain(until: { scm.commitState.canCommit }, "ステージ済みができる")
    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: commandReturn))
    pumpMain(until: { scm.control.operations.isEmpty }, timeout: 20, "コミット")
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "typed\n")
    XCTAssertEqual(repo.git(["rev-parse", "origin/main"]).stdoutText, origin, "push しない")
  }

  /// メッセージ欄の中身が外から変わった（コミットで空になった）ら、それまでの取り消しの履歴は捨てる——⌘Z は差し替え前の
  /// 文へ戻らず、今の文の外を戻そうとして例外を投げることもない。
  func testAnOutsideChangeOfTheMessageDiscardsTheFieldsUndo() throws {
    let hosted = host(try TempGitRepo())
    let text = try type("typed message", in: hosted)

    hosted.scm.control.message = ""
    pumpMain(until: { text.string.isEmpty }, "外の変化が欄に届く")
    XCTAssertEqual(text.undoManager?.canUndo, false)
    text.undoManager?.undo()
    XCTAssertEqual(text.string, "")
  }

  /// 欄の取り消しはその欄の中で閉じる——cd で欄が作り直された後の ⌘Z は前の worktree のメッセージを戻さず、新しい欄の
  /// 打鍵だけを戻す。
  func testUndoInTheMessageAfterChangingTheRootLeavesThePreviousRootsMessage() throws {
    let hosted = host(try TempGitRepo())
    let old = try type("typed message", in: hosted)
    let previous = hosted.scm.control
    let other = try TempGitRepo(name: "orbe-scm-pane-other")

    hosted.pane.setRoot(other.root)
    pumpMain(
      until: { self.messageField(in: hosted.pane).map { $0 !== old } ?? false }, "新しい根の欄")
    let new = try type("new", in: hosted)
    XCTAssertTrue(undo(in: hosted))
    XCTAssertEqual(new.string, "")
    XCTAssertEqual(hosted.scm.control.message, "")
    _ = undo(in: hosted)
    XCTAssertEqual(previous.message, "typed message", "新しい欄に戻すものが無ければ何も戻さない")
  }

  /// 窓から外れた欄の取り消しはどこにも効かない——パネルを閉じて開き直した欄の ⌘Z は、閉じている間に別の窓が打ち足した
  /// 分も、閉じる前の打鍵も戻さない。
  func testUndoInAReopenedMessageKeepsWhatAnotherWindowTyped() throws {
    let repo = try TempGitRepo()
    let first = host(repo)
    let second = host(repo, showsPanel: false)
    _ = try type("first", in: first)
    first.pane.shell.selectPanel(.files)
    pumpMain(until: { self.messageField(in: first.pane) == nil }, "閉じたパネルの欄が外れる")

    second.pane.shell.selectPanel(.sourceControl)
    _ = try type(" more", in: second)
    first.pane.shell.selectPanel(.sourceControl)
    pumpMain(until: { self.messageField(in: first.pane)?.string == "first more" }, "開き直した欄")
    first.window.makeFirstResponder(try XCTUnwrap(messageField(in: first.pane)))
    _ = undo(in: first)
    XCTAssertEqual(first.scm.control.message, "first more")
    XCTAssertEqual(messageField(in: first.pane)?.string, "first more")
  }

  /// パネルを出していない面でも、件数は status の変化に追いつく。その間、行の組とグラフは作らない。
  func testTheCountFollowsTheStatusWhileThePanelIsNotShown() throws {
    let repo = try TempGitRepo()
    let hosted = host(repo, showsPanel: false)
    try repo.write("a.txt", "edited\n")
    pumpMain(until: { hosted.scm.count == 1 }, "編集で 1")
    try repo.write("n.txt", "new\n")
    pumpMain(until: { hosted.scm.count == 2 }, "未追跡を足して 2")
    XCTAssertTrue(hosted.scm.layout.items.isEmpty, "行は組まない")
    XCTAssertNil(hosted.scm.graph, "グラフは読まない")
  }

  /// パネルを出したまま cd すると、列は新しい根の行を出し、押した行は新しい根の diff を開く。
  func testAfterChangingTheRootTheListShowsAndOpensTheNewRootsRows() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let other = try TempGitRepo(name: "orbe-scm-pane-other")
    try other.write("m.txt", "new\n")
    let hosted = host(repo)
    pumpMain(until: { hosted.scm.changes.changes.map(\.path) == ["a.txt"] }, "前の根の行")

    hosted.pane.setRoot(other.root)
    pumpMain(until: { hosted.scm.changes.changes.map(\.path) == ["m.txt"] }, "新しい根の行")
    let row = try row(hosted, .changes, "m.txt")
    pumpMain(until: { self.slot(row, in: hosted.pane) != nil }, timeout: 3, "載っている列に新しい根の行")
    let slot = try XCTUnwrap(slot(row, in: hosted.pane))
    let list = try XCTUnwrap(slot.superview)
    list.mouseDown(
      with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: list.convert(NSPoint(x: 40, y: slot.frame.midY), to: nil),
        modifierFlags: [], timestamp: 0, windowNumber: hosted.window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1)!)
    XCTAssertEqual(
      hosted.tab.group.editor.activeID,
      .diff(EditorDiff.Key(root: other.root, path: "m.txt", kind: .workingTree)))
  }

  /// 面のメッセージ欄（載っていなければ nil）。
  private func messageField(in view: NSView) -> ScmMessageTextView? {
    (view as? ScmMessageTextView) ?? view.subviews.lazy.compactMap(messageField(in:)).first
  }

  /// メッセージ欄に焦点を入れ、末尾に `text` を打つ（打った文が欄の外へ届くまで待つ）。
  @discardableResult
  private func type(_ text: String, in hosted: Hosted) throws -> ScmMessageTextView {
    pumpMain(until: { self.messageField(in: hosted.pane) != nil }, "メッセージ欄")
    let field = try XCTUnwrap(messageField(in: hosted.pane))
    hosted.window.makeFirstResponder(field)
    let expected = field.string + text
    field.insertText(text, replacementRange: NSRange(location: field.string.utf16.count, length: 0))
    pumpMain(until: { hosted.scm.control.message == expected }, "打った文が欄の外へ届く")
    return field
  }

  /// 編集メニューの「取り消す」と同じく、窓の焦点から ⌘Z の操作を送る（受け手が無ければ false）。
  private func undo(in hosted: Hosted) -> Bool {
    hosted.window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) ?? false
  }

  /// 面に載っているソース管理の列のうち、今のパネルの行 `row` を描いている枠（今のパネルの列が載っていなければ nil）。
  func slot(_ row: Int, in pane: EditorPaneView) -> ScmRowView? {
    func lists(in view: NSView) -> [RowListView<ScmListSource>] {
      (view as? RowListView<ScmListSource>).map { [$0] } ?? view.subviews.flatMap(lists(in:))
    }
    return lists(in: pane).first { $0.source.panel === pane.scm }?.subviews
      .compactMap { $0 as? ScmRowView }.first { $0.row == row && !$0.isHidden }
  }
}
