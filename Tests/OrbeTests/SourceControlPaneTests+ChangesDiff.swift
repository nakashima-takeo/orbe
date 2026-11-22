import AppKit
import XCTest

@testable import Orbe

/// Changes の画面の本体——Changes を出したときに diff が無ければ、先頭のファイルの行の diff を焦点を動かさずに出して、その行を
/// 選択表示する。出した diff は、ステージで行が移っても残り、変更が 1 件も無くなると消える。
///
/// 壊れると何が起きるか。Changes を出しても本体が空のまま。コミットのメッセージを打ち始めたのに、自動で開いた diff が焦点を
/// 奪う。本体の diff が左の列のどの行か分からない。ステージした途端に本体の diff が消える。変更が無くなっても前の diff が本体に
/// 残る。
extension SourceControlPaneTests {
  /// レールで Changes を出すと、diff を開いていなければ先頭のファイルの行の diff が本体に出て、その行が選択表示される。焦点は
  /// レールが入れたメッセージ欄に残る。
  func testShowingChangesOpensTheFirstFileRowsDiffAndLeavesTheFocus() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    try repo.write("b.txt", "new\n")
    let hosted = host(repo)
    pumpMain(until: { hosted.pane.diff?.content == .ready }, "本体に diff が出る")
    XCTAssertEqual(
      hosted.pane.diff?.id, EditorDiff.Key(root: repo.root, path: "a.txt", kind: .workingTree))
    XCTAssertEqual(hosted.scm.selection, ScmRowID(section: .changes, path: "a.txt"))
    let field = try XCTUnwrap(messageField(in: hosted.pane))
    XCTAssertTrue(hosted.window.firstResponder === field, "焦点はメッセージ欄のまま")
  }

  /// Changes の diff は、ステージで行が別の区分へ移っても本体に残り、変更が 1 件も無くなると本体から消える。
  func testTheChangesDiffStaysWhileThereAreChangesAndGoesWithTheLast() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    pumpMain(until: { hosted.pane.diff != nil }, "前提: 本体に diff が出る")
    let shown = hosted.pane.diff

    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    pumpMain(until: { hosted.scm.changes.staged.count == 1 }, "行がステージされている変更へ移る")
    XCTAssertTrue(hosted.pane.diff === shown, "本体の diff はそのまま")

    XCTAssertTrue(repo.git(["reset", "-q", "--hard"]).isSuccess)
    pumpMain(until: { hosted.scm.count == 0 }, "変更が無くなる")
    pumpMain(until: { hosted.pane.diff == nil }, "本体から diff が消える")
  }
}
