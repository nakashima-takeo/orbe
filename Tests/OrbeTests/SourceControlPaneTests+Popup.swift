import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// コミットのポップアップの開閉（エディター面に結んだもの）——変更の列の ⌘↑ は、どの行を選んでいても開いてメッセージ欄へ
/// フォーカスを入れる。コミットが通れば閉じてフォーカスは開く前の場所へ戻り（変更の列の行が無くなっていれば本体へ移り）、
/// 最後のコミットの取り消しと、コミットの失敗では開いたまま。
/// 閉じても失敗は消えない（赤い行に出していたコミットの操作の失敗も残る）。▾ のメニューは開くとフォーカスを行の列へ移し、
/// 何も選ばずに始まり、esc はメニューだけを閉じて欄へ戻す。
///
/// 壊れると何が起きるか。列の途中の行で ⌘↑ を押しても開かない。コミットの後もポップアップが残る。フォーカスが窓へ落ちて
/// キーがどこにも届かない。取り消した直後に書き直そうとすると閉じている。閉じると、hook の
/// 失敗の理由やプルの失敗が消え、理由を見られない。▾ を開いた直後の ↵ で思わず amend する。メニューの esc でポップアップごと閉じて
/// 打ちかけを見失う。
extension SourceControlPaneTests {
  /// 上向きの矢印のキーの字。
  private static let upArrow = String(UnicodeScalar(NSEvent.SpecialKey.upArrow.rawValue)!)

  /// 変更の列のファイル行（先頭の見出しでない行）を選んで ⌘↑ を押すとポップアップが開き、メッセージ欄にフォーカスが入る。
  /// ↵ のコミットが通ると閉じ、フォーカスは変更の列へ戻る（コミットの後も列に行が残る場合）。
  ///
  /// 閉じたことは、操作の列が空になるのを待った直後に確かめ、閉じることを条件にして待たない。コミットのように段が 1 つの
  /// 操作では、`SourceControl.finish` が、操作を列から外すのと同じ呼び出しの中でポップアップを閉じるため。取り消しでは
  /// 閉じないこと（`testUndoingTheLastCommitKeepsThePopupOpen`）は、同じ時点で確かめている。
  func testCommandUpInTheListOpensThePopupAndACommitClosesItBackToTheList() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    try repo.write("b.txt", "new\n")
    let hosted = host(repo, showsPanel: false)
    let pane = hosted.pane
    let popup = pane.commitPopup
    pane.switchScreen(.changes)
    let list = pane.scmList.list
    pumpMain(until: { hosted.window.firstResponder === list }, "前提: 変更の列にフォーカス")
    hosted.scm.select(ScmRowID(section: .changes, path: "b.txt"))

    XCTAssertTrue(pane.performKeyEquivalent(with: .key(Self.upArrow)))
    XCTAssertTrue(popup.isOpen, "ファイル行からでも開く")
    pumpMain(until: { self.messageFieldHasFocus(hosted) }, "メッセージ欄にフォーカス")

    let field = try type("subject", in: hosted)
    field.keyDown(with: .key("\r", []))
    pumpMain(until: { hosted.scm.control.operations.isEmpty }, timeout: 20, "コミット")
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "subject\n")
    XCTAssertFalse(
      popup.isOpen,
      "操作の列が空になった時点で閉じている（この時点で閉じないなら、testUndoingTheLastCommitKeepsThePopupOpen の「開いたまま」は、閉じる前を見ているだけになる）"
    )
    pumpMain(until: { hosted.window.firstResponder === list }, "フォーカスは変更の列へ戻る")
  }

  /// 変更の列から開いたポップアップで変更を全部コミットし、列の行が無くなれば、閉じた後のフォーカスは本体へ移る。
  func testACommitThatEmptiesTheListMovesTheFocusToTheBody() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo, showsPanel: false)
    let pane = hosted.pane
    pane.switchScreen(.changes)
    pumpMain(until: { hosted.window.firstResponder === pane.scmList.list }, "前提: 変更の列にフォーカス")
    pane.commitPopup.open()

    let field = try type("subject", in: hosted)
    field.keyDown(with: .key("\r", []))
    pumpMain(until: { hosted.scm.control.operations.isEmpty }, timeout: 20, "コミット")
    pumpMain(
      until: {
        hosted.scm.layout.items.isEmpty && hosted.window.firstResponder === pane.focusTarget
      }, "列の行が無くなり、フォーカスは本体へ")
  }

  /// ▾ の「最後のコミットを取り消す」が通っても、ポップアップは開いたまま（続けて書き直せる）。
  func testUndoingTheLastCommitKeepsThePopupOpen() throws {
    let repo = try TempGitRepo()
    let first = repo.head()
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "b.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "second"]).isSuccess)
    let hosted = host(repo)
    let scm = hosted.scm
    let popup = hosted.pane.commitPopup
    pumpMain(until: { scm.commitState.canUndo }, "前提: 取り消せる")

    popup.toggleMenu()
    popup.menu.commit(ScmCommitPopup.MenuItem.undo)
    pumpMain(
      until: { scm.control.operations.isEmpty && repo.head() == first }, timeout: 20, "取り消す")
    XCTAssertTrue(popup.isOpen, "取り消しでは閉じない")
  }

  /// コミットが失敗しても開いたまま。閉じても、コミットの操作の失敗は残る（閉じている間は置き場の失敗の札に出る）。ポップアップの
  /// 外（置き場の失敗の札）に出す失敗（プルの失敗）も、閉じても残る。
  func testClosingThePopupKeepsTheFailure() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let hook = repo.dir.appendingPathComponent(".git/hooks/pre-commit")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    let hosted = host(repo)
    let control = hosted.scm.control
    let popup = hosted.pane.commitPopup
    let field = try type("subject", in: hosted)
    pumpMain(until: { hosted.scm.commitState.canCommit }, "前提: コミットが押せる")

    field.keyDown(with: .key("\r", []))
    pumpMain(until: { control.operations.isEmpty }, timeout: 20, "失敗するコミット")
    XCTAssertEqual(control.failure?.kind, .commit)
    XCTAssertTrue(popup.isOpen, "失敗では閉じない")
    popup.toggle()
    XCTAssertEqual(control.failure?.kind, .commit, "閉じてもコミットの失敗は残る")

    popup.open()
    hosted.scm.pull()
    pumpMain(until: { control.operations.isEmpty }, timeout: 20, "upstream の無いプル")
    XCTAssertEqual(control.failure?.kind, .pull, "前提: プルの失敗")
    popup.toggle()
    XCTAssertEqual(control.failure?.kind, .pull, "プルの失敗は閉じても残る")
  }

  /// ▾ を開くとフォーカスはメニューの行の列へ移り、ポップアップは開いたまま。何も選ばずに始まるので、開いた直後の ↵ は何もしない
  /// （amend を選べるときでも）。esc はメニューだけを閉じ、フォーカスはメッセージ欄へ戻る。
  func testTheMenuStartsWithNothingChosenAndEscapeClosesOnlyTheMenu() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    let scm = hosted.scm
    let popup = hosted.pane.commitPopup
    let rows = popup.menu.list.list
    pumpMain(
      until: { self.messageFieldHasFocus(hosted) && scm.commitState.canAmend },
      "前提: 欄にフォーカスがあり、amend できる")

    popup.toggleMenu()
    pumpMain(until: { hosted.window.firstResponder === rows }, "行の列にフォーカス")
    nextTurn()
    XCTAssertTrue(popup.isOpen, "行の列へ移っても開いたまま")

    deliverKeyDown(.key("\r", []), to: hosted.window)
    XCTAssertTrue(scm.control.operations.isEmpty, "何も選んでいない ↵ は何も起こさない")
    XCTAssertTrue(popup.menu.isOpen)

    deliverKeyDown(.key("\u{1b}", []), to: hosted.window)
    XCTAssertFalse(popup.menu.isOpen)
    pumpMain(until: { self.messageFieldHasFocus(hosted) }, "メッセージ欄へ戻る")
    nextTurn()
    XCTAssertTrue(popup.isOpen, "esc はメニューだけを閉じる")
  }
}
