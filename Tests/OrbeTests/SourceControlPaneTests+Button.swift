import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// コミットのポップアップの ▾ のメニューは「コミット」の可否に縛られず開き、amend・取り消しに届き、開いた時点の姿で照らす。
///
/// 壊れると何が起きるか。欄が空の間（ステージ済みの一部をコミットして残りを置いた直後など）に、取り消しと amend に届かない。
/// ▾ を開いている間にエージェントがコミットすると、選んだ取り消しがそのコミットを消す。
extension SourceControlPaneTests {
  /// 欄が空で「コミット」が押せない間も ▾ のメニューは開き、最後のコミットを取り消せる。
  func testWhileTheCommitIsDisabledTheMenuStillUndoesTheLastCommit() throws {
    let repo = try TempGitRepo()
    let first = repo.head()
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "b.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "second"]).isSuccess)
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    let scm = hosted.scm
    let popup = hosted.pane.commitPopup
    pumpMain(
      until: { scm.changes.changes.count == 1 && scm.isHeadPushed == false },
      "変更の行と、push 済みでない HEAD")
    XCTAssertFalse(scm.commitState.canCommit, "前提: 欄が空ならコミットは押せない")

    popup.toggleMenu()
    XCTAssertTrue(popup.menu.isOpen, "▾ は開く")
    let rows = try XCTUnwrap(popup.menu.content?.rows)
    XCTAssertEqual(
      (0..<rows.count).compactMap { rows.id(at: $0) },
      [ScmCommitPopup.MenuItem.amend, .undo].map(AnyHashable.init),
      "amend と取り消しは選べ、コミットしてプッシュは選べない")
    popup.menu.commit(ScmCommitPopup.MenuItem.undo)
    pumpMain(
      until: { scm.control.operations.isEmpty && repo.head() == first }, timeout: 20, "取り消す")
  }

  /// ▾ の取り消しは開いた時点の姿で照らす——開いている間に外でコミットされ、行が追いついてから選んでも、外のコミットを
  /// 取り消さずに断る。
  func testUndoChosenFromTheMenuAfterAnOutsideCommitWhileItIsOpenIsRefused() throws {
    let repo = try TempGitRepo()
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "b.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "second"]).isSuccess)
    try repo.write("z.txt", "agent\n")
    let hosted = host(repo)
    let scm = hosted.scm
    let popup = hosted.pane.commitPopup
    pumpMain(
      until: { scm.changes.changes.count == 1 && scm.isHeadPushed == false },
      "変更の行と、push 済みでない HEAD")
    popup.toggleMenu()

    XCTAssertTrue(repo.git(["add", "z.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "agent"]).isSuccess)
    let (head, status) = (repo.head(), repo.git(["status", "--porcelain"]).stdoutText)
    pumpMain(
      until: { scm.changes.head == head && scm.changes.changes.isEmpty }, "行が外のコミットに追いつく")
    XCTAssertTrue(popup.menu.isOpen, "前提: メニューは開いたまま")
    popup.menu.commit(ScmCommitPopup.MenuItem.undo)
    pumpMain(until: { scm.control.operations.isEmpty }, timeout: 20, "取り消し")
    XCTAssertEqual(scm.control.failure?.cause, .git(.contentMismatch))
    XCTAssertEqual(repo.head(), head, "外のコミットは残る")
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, status)
  }
}
