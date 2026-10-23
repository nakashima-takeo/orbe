import AppKit
import XCTest

@testable import Orbe

/// 変換中のメッセージ欄——押した・開いた時点の写しが変換を確定するので、見えている字が全部コミットに入り、通った後の欄は
/// 空のまま残る。ボタンの姿は見えている字（変換中の字を含む）で決まる。
///
/// 壊れると何が起きるか。日本語入力で変換を確定しないまま ✓・ボタン・▾・… を押すと、未確定の字が抜けたコミットができる。
/// 変換を終えると、コミット済みの文が欄に戻り、続けた ↵ が残りの変更をその文でコミットする。変換中の字だけが見えている
/// のにボタンが押せない姿になる（押せば ⌘↵ と同じく確定してから働くのに）。
extension SourceControlPaneTests {
  /// 欄に変換中の字を置く（IME の打鍵と同じ口）。
  private func compose(_ text: String, in field: ScmMessageTextView) {
    field.setMarkedText(
      text, selectedRange: NSRange(location: text.utf16.count, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
  }

  /// ✓ と同じ道（押した時点の写し → コミット）で、変換中だった字までコミットの題に入り、通った後は欄もメッセージも空。
  func testCommittingWhileComposingTakesEveryVisibleCharacter() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    let scm = hosted.scm
    pumpMain(until: { scm.changes.changes.count == 1 }, "変更の行")
    let field = try type("abc", in: hosted)
    compose("かん", in: field)
    XCTAssertEqual(scm.composition, "かん")
    XCTAssertEqual(scm.control.message, "abc", "前提: 変換中の字はメッセージに入っていない")

    let snapshot = scm.commitSnapshot()
    XCTAssertFalse(field.hasMarkedText(), "写しが変換を確定する")
    XCTAssertEqual(scm.control.message, "abcかん")
    XCTAssertTrue(snapshot.state.canCommit)
    snapshot.commit()
    pumpMain(until: { scm.control.operations.isEmpty && field.string.isEmpty }, timeout: 20, "コミット")
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "abcかん\n")
    XCTAssertEqual(scm.control.message, "")
  }

  /// 変換中の字だけが欄にあるとき、✓・ボタン・▾ は押せる姿。変換が終われば（取り消せば）押せない姿に戻る。
  func testOnlyAComposingTextMakesTheCommitPressable() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    let scm = hosted.scm
    pumpMain(until: { scm.changes.changes.count == 1 }, "変更の行")
    let field = try type("", in: hosted)
    XCTAssertFalse(scm.commitState.canCommit, "前提: 空の欄")

    compose("ろぐいん", in: field)
    XCTAssertEqual(scm.control.message, "")
    XCTAssertTrue(scm.commitState.canCommit)
    XCTAssertTrue(scm.commitState.isButtonEnabled)

    compose("", in: field)
    XCTAssertFalse(scm.commitState.canCommit, "変換を取り消した")
  }
}
