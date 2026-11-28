import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// メッセージ欄の押し続けた ↵・⌘↵——押した瞬間だけがコミットの合図で、続くキーリピートは何も起こさない。⇧↵ の押し続けは
/// 改行が続く。コミットのポップアップ・▾ のメニュー・面の中の破棄の確認を esc で閉じた後の押し続けた esc は、戻った先に
/// 届かない。
///
/// 壊れると何が起きるか。変換の確定に使った ↵ をそのまま押し続けると、打ちかけのメッセージでコミットされる（⌘↵ なら push
/// まで届く）。すぐに断られたコミットが押し続けている間に試し直され、見直していない姿のまま通る。⇧↵ を押し続けても改行が
/// 1 つしか入らない。esc でポップアップや確認を閉じた後も押し続けると、フォーカスが戻った変更の列の選択が外れて、見ていた
/// 行を見失う。メニューを閉じた後なら、ポップアップごと閉じて打ちかけを見失う。
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

  /// コミットのポップアップ・面の中の破棄の確認を esc で閉じた後、押し続けた esc は、フォーカスが戻った変更の列の選択を
  /// 外さない。押し続けでない esc は外す。
  func testHeldEscapeAfterClosingThePopupOrTheConfirmKeepsTheSelection() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo, showsPanel: false)
    let scm = hosted.scm
    let list = hosted.pane.scmList.list
    hosted.pane.switchScreen(.changes)
    pumpMain(
      until: { scm.changes.changes.count == 1 && hosted.window.firstResponder === list },
      "前提: 変更の行があり、変更の列にフォーカス")
    let row = ScmRowID(section: .changes, path: "a.txt")
    let deliver = escapeThroughTheMonitor(hosted, to: list)

    scm.select(row)
    hosted.pane.commitPopup.open()
    pumpMain(until: { self.messageFieldHasFocus(hosted) }, "前提: 欄にフォーカス")
    deliverKeyDown(.key("\u{1b}", []), to: hosted.window)
    XCTAssertFalse(hosted.pane.commitPopup.isOpen, "前提: esc で閉じる")
    pumpMain(until: { hosted.window.firstResponder === list }, "前提: 変更の列へ戻る")
    deliver(true)
    XCTAssertEqual(scm.selection, row, "ポップアップを閉じた後の押し続けた esc では外れない")
    deliver(false)
    XCTAssertNil(scm.selection, "押し続けでない esc で外れる")

    scm.select(row)
    scm.press(try self.row(hosted, .changes, "a.txt"), .discard, in: scm.layout)
    XCTAssertTrue(hosted.pane.confirm.isShown, "前提: 破棄の確認が出る")
    try XCTUnwrap(hosted.window.firstResponder).keyDown(with: .key("\u{1b}", []))
    XCTAssertFalse(hosted.pane.confirm.isShown, "前提: esc で閉じる")
    pumpMain(until: { hosted.window.firstResponder === list }, "前提: 変更の列へ戻る")
    deliver(true)
    XCTAssertEqual(scm.selection, row, "確認を閉じた後の押し続けた esc では外れない")
  }

  /// ▾ のメニューを esc で閉じた後、押し続けた esc は、フォーカスが戻ったメッセージ欄でポップアップを閉じない。
  func testHeldEscapeAfterClosingTheMenuKeepsThePopupOpen() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    let popup = hosted.pane.commitPopup
    pumpMain(until: { self.messageFieldHasFocus(hosted) }, "前提: 欄にフォーカス")
    popup.toggleMenu()
    pumpMain(until: { hosted.window.firstResponder === popup.menu.list.list }, "前提: 行の列にフォーカス")
    deliverKeyDown(.key("\u{1b}", []), to: hosted.window)
    pumpMain(until: { self.messageFieldHasFocus(hosted) }, "前提: メニューだけが閉じて欄へ戻る")
    let field = try XCTUnwrap(hosted.window.firstResponder)
    escapeThroughTheMonitor(hosted, to: field)(true)
    nextTurn()
    XCTAssertTrue(popup.isOpen, "メニューを閉じた後の押し続けた esc では閉じない")
  }

  /// esc を、窓のイベントの監視を通してから `responder` へ渡す（`isRepeat` は押し続けて届いた esc）——押し続けた esc を
  /// 捨てるのは監視で、テストから窓へ送るキーはそこを通らないので、先に監視の判定（`keyRepeatIsSwallowed`）を呼び、
  /// 捨てなかったものだけを渡す。
  private func escapeThroughTheMonitor(_ hosted: Hosted, to responder: NSResponder) -> (Bool) ->
    Void
  {
    { isRepeat in
      let event = NSEvent.key("\u{1b}", [], isRepeat: isRepeat)
      if !hosted.pane.keyRepeatIsSwallowed(event) { responder.keyDown(with: event) }
    }
  }
}
