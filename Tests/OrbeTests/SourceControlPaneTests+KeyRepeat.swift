import XCTest

@testable import Orbe

/// メッセージ欄の押し続けた ↵・⌘↵——押した瞬間だけがコミットの合図で、続くキーリピートは何も起こさない。⇧↵ の押し続けは
/// 改行が続く。
///
/// 壊れると何が起きるか。変換の確定に使った ↵ をそのまま押し続けると、打ちかけのメッセージでコミットされる（⌘↵ なら push
/// まで届く）。すぐに断られたコミットが押し続けている間に試し直され、見直していない姿のまま通る。⇧↵ を押し続けても改行が
/// 1 つしか入らない。
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
        scm.focusedArea == .message && scm.commitState.canCommit
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
}
