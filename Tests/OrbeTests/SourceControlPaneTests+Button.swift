import AppKit
import XCTest

@testable import Orbe

/// コミットボタンは主の働きと ▾ で 1 つの可否を持ち、区分見出しの … はボタンの姿に縛られず amend・取り消しに届く。
///
/// 壊れると何が起きるか。主の側が暗いのに ▾ だけ開いて、1 つのボタンの中で明暗が割れる。欄が空の間（ステージ済みの一部を
/// コミットして残りを置いた直後など）に、取り消しと amend に届かない。
extension SourceControlPaneTests {
  /// 面に載っているメニューの当たりのうち、説明が `key` のもの。
  func menuAnchor(_ key: L10nKey, in pane: EditorPaneView) -> ScmMenuAnchor.AnchorView? {
    func anchors(in view: NSView) -> [ScmMenuAnchor.AnchorView] {
      (view as? ScmMenuAnchor.AnchorView).map { [$0] } ?? view.subviews.flatMap(anchors(in:))
    }
    let help = Set(Language.allCases.map { L10n.string(key, $0) })
    return anchors(in: pane).first { help.contains($0.toolTip ?? "") }
  }

  /// 変更があり欄が空の間は ▾ も開かず、欄に打てば開く。その間も … を開けば、最後のコミットを取り消せる。
  func testWhileTheButtonIsDisabledTheMoreMenuStillUndoesTheLastCommit() throws {
    let repo = try TempGitRepo()
    let first = repo.head()
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "b.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "second"]).isSuccess)
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    let scm = hosted.scm
    pumpMain(
      until: { scm.changes.changes.count == 1 && scm.isHeadPushed == false },
      "変更の行と、push 済みでない HEAD")
    hosted.pane.layoutSubtreeIfNeeded()
    let caret = try XCTUnwrap(menuAnchor(.editorScmCommitActions, in: hosted.pane))
    XCTAssertNil(caret.menuMaker, "欄が空なら ▾ も開かない")

    let more = try XCTUnwrap(menuAnchor(.editorScmMoreActions, in: hosted.pane)?.menuMaker?())
    let language = hosted.pane.localization.language
    let titles = [L10nKey.editorScmAmend, .editorScmUndo].map { L10n.string($0, language) }
    XCTAssertEqual(Array(more.items.suffix(2).map(\.title)), titles, "… の末尾に amend と取り消し")
    XCTAssertTrue(more.items.suffix(2).allSatisfy(\.isEnabled), "ボタンが押せなくても押せる")
    more.performActionForItem(at: more.items.count - 1)
    pumpMain(
      until: { scm.control.operations.isEmpty && repo.head() == first }, timeout: 20, "取り消す")

    scm.control.message = "typed"
    pumpMain(
      until: {
        hosted.pane.layoutSubtreeIfNeeded()
        return caret.menuMaker != nil
      }, "欄に打てば ▾ も開く")
  }
}
