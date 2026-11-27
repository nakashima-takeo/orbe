import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 変換中のメッセージ欄——押した・開いた時点の写しが変換を確定するので、見えている字が全部コミットに入り、通った後の
/// メッセージは空のまま残る。「コミット」の可否は見えている字（変換中の字を含む）で決まる。変換中にポップアップを閉じても、
/// 変換は確定してメッセージに残る。
///
/// 壊れると何が起きるか。日本語入力で変換を確定しないまま「コミット」・▾ を押すと、未確定の字が抜けたコミットができる。
/// 変換を終えると、コミット済みの文が欄に戻り、続けた ↵ が残りの変更をその文でコミットする。変換中の字だけが見えている
/// のに「コミット」が押せない姿になる（押せば ⌘↵ と同じく確定してから働くのに）。IME で確定した後、コミットで空になった
/// 欄でも「コミット」が押せる姿に残る。変換中にポップアップを閉じると、変換中の字が消える。
extension SourceControlPaneTests {
  /// 欄に変換中の字を置く（IME の打鍵と同じ口）。
  func compose(_ text: String, in field: MessageTextView) {
    field.setMarkedText(
      text, selectedRange: NSRange(location: text.utf16.count, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
  }

  /// 「コミット」と同じ道（押した時点の写し → コミット）で、変換中だった字までコミットの題に入り、通った後はメッセージが空。
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
    pumpMain(
      until: { scm.control.operations.isEmpty && scm.control.message.isEmpty }, timeout: 20,
      "コミット")
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "abcかん\n")
  }

  /// 変換中の字だけが欄にあるとき、「コミット」は押せる姿。変換を取り消せば押せない姿に戻る。IME が確定すれば字は
  /// メッセージへ移り、その後の姿はメッセージだけで決まる。
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

    compose("", in: field)
    XCTAssertFalse(scm.commitState.canCommit, "変換を取り消した")

    compose("ろぐいん", in: field)
    field.insertText("ログイン", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(scm.control.message, "ログイン", "IME の確定")
    scm.control.message = ""
    XCTAssertFalse(scm.commitState.canCommit, "確定した後は、終わった変換の字で押せる姿に残らない")
  }

  /// 変換中にポップアップを閉じると、変換中の字は確定してメッセージに残る。
  func testClosingThePopupWhileComposingKeepsTheComposedText() throws {
    let hosted = host(try TempGitRepo())
    let scm = hosted.scm
    let field = try type("abc", in: hosted)
    compose("かん", in: field)
    XCTAssertEqual(scm.control.message, "abc", "前提: 変換中の字はメッセージに入っていない")

    hosted.pane.commitPopup.toggle()
    XCTAssertEqual(scm.control.message, "abcかん")
  }
}
