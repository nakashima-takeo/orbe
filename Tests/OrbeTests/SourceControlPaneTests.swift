import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// エディター面に結んだソース管理パネル——行は区分に合った diff を仮のタブで開き、追跡中のファイルの破棄は確かめてから行い、
/// メッセージ欄の ⌘↵ はコミットだけを起こす。
///
/// 壊れると何が起きるか。「ステージされている変更」の行で作業ツリーの diff が開き、コミットする中身と違うものを見て確かめた
/// ことになる。追跡中のファイルの編集が確認なしに消え、戻せない。ボタンが「同期」の間に欄で ⌘↵ を打つと、キー 1 つで
/// push が走る。
@MainActor
final class SourceControlPaneTests: OrbeTestCase {
  struct Hosted {
    let repo: TempGitRepo
    let tab: TerminalTab
    let pane: EditorPaneView
    let window: NSWindow
    @MainActor var scm: ScmPanel { pane.scm }
  }

  /// 根 `repo` の連の面だけを窓に載せ、ソース管理パネルを出す。
  private func host(_ repo: TempGitRepo) -> Hosted {
    let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = pane
    pane.layoutSubtreeIfNeeded()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    pane.shell.selectPanel(.sourceControl)
    return Hosted(repo: repo, tab: tab, pane: pane, window: window)
  }

  private func row(_ hosted: Hosted, _ section: ScmSection, _ path: String) throws -> Int {
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

    hosted.scm.click(try row(hosted, .staged, "a.txt"))
    let staged = EditorTab.Key.diff(EditorDiff.Key(root: repo.root, path: "a.txt", kind: .staged))
    XCTAssertEqual(editor.activeID, staged)
    XCTAssertEqual(editor.previewID, staged)

    hosted.scm.click(try row(hosted, .changes, "a.txt"))
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

    hosted.scm.press(try row(hosted, .changes, "n.txt"), .discard)
    XCTAssertNil(hosted.window.attachedSheet, "未追跡だけなら確かめない")
    pumpMain(
      until: {
        hosted.scm.control.operations.isEmpty && !FileManager.default.fileExists(atPath: untracked)
      },
      "ゴミ箱へ")

    hosted.scm.press(try row(hosted, .changes, "a.txt"), .discard)
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
}
