import OrbeTestSupport
import XCTest

@testable import Orbe

/// メッセージ欄の押し続けた ↵・⌘↵——押した瞬間だけがコミットの合図で、続くキーリピートは何も起こさない。⇧↵ の押し続けは
/// 改行が続く。変更の列で、キーリピートの esc は選択を外さない。
///
/// 壊れると何が起きるか。変換の確定に使った ↵ をそのまま押し続けると、打ちかけのメッセージでコミットされる（⌘↵ なら push
/// まで届く）。すぐに断られたコミットが押し続けている間に試し直され、見直していない姿のまま通る。⇧↵ を押し続けても改行が
/// 1 つしか入らない。esc でポップアップを閉じた後も押し続けると、フォーカスが戻った変更の列の選択が外れ、見ていた行を
/// 見失う。
extension SourceControlPaneTests {
  /// コミットできる姿でも、↵・⌘↵ のリピートはコミットも改行も起こさない（⌘↵ は本文や chrome へ流さずに食う）。⇧↵ の
  /// リピートは改行が続く。
  func testHeldReturnAndCommandReturnInTheMessageDoNothing() throws {
    let repo = try TempGitRepo()
    repo.addOrigin()
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    let scm = hosted.scm
    let field = try type("subject", in: hosted)
    pumpMain(
      until: {
        self.messageFieldHasFocus(hosted) && scm.commitState.canCommit
          && scm.commitState.canCommitAndPush
      }, "前提: 欄に焦点があり、コミットもコミットしてプッシュもできる")
    let head = repo.head()

    field.keyDown(with: .key("\r", [], isRepeat: true))
    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: .key("\r", isRepeat: true)))
    XCTAssertTrue(scm.control.operations.isEmpty, "コミットもプッシュも始まらない")
    XCTAssertEqual(field.string, "subject", "改行も入らない")
    XCTAssertEqual(repo.head(), head)

    field.keyDown(with: .key("\r", [.shift], isRepeat: true))
    XCTAssertEqual(field.string, "subject\n", "⇧↵ のリピートは改行を入れる")
  }

  /// 変更の列で、esc のキーリピートは選択を外さず、押した瞬間の esc は外す。
  func testHeldEscapeInTheListKeepsTheSelection() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    let scm = hosted.scm
    let list = hosted.pane.scmList.list
    pumpMain(until: { scm.changes.changes.count == 1 }, "変更の行")
    hosted.pane.popup.close(.escape)
    hosted.window.makeFirstResponder(list)
    let row = ScmRowID(section: .changes, path: "a.txt")
    scm.select(row)

    list.keyDown(with: .key("\u{1b}", [], isRepeat: true))
    XCTAssertEqual(scm.selection, row, "キーリピートの esc では外れない")
    list.keyDown(with: .key("\u{1b}", []))
    XCTAssertNil(scm.selection, "押した瞬間の esc で外れる")
  }
}
