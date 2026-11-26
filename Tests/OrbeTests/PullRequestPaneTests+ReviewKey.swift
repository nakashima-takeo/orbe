import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR の一覧の ⌘↑——選んでいる行に依らず、レビューのポップアップを開き、全体へのコメント欄に焦点を入れる。送って閉じれば、
/// 焦点は一覧へ戻る。
///
/// 壊れると何が起きるか: 一覧でファイルを見ながらマウスを使わずにレビューを書き始められない。先頭より下の行を選んでいると
/// ⌘↑ が効かない。開いても欄に焦点が入らず、打鍵が一覧へ入る。送った後に焦点が本文へ移り、↑↓ で続けてファイルを見られない。
extension PullRequestPaneTests {
  /// 先頭でないファイルの行を選んだ一覧で ⌘↑ を押すと、レビューのポップアップが開き、全体へのコメント欄に焦点が入る。書いて
  /// ⌘↵ で送ると、焦点は一覧へ戻り、選択は開く前のまま。
  func testCommandUpInTheListOpensTheReviewAndSendingReturnsToTheList() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    let review = hosted.pane.reviewPopup
    pumpMain(
      until: { review.canOpen && hosted.pane.pullRequest.state?.diffEnds != nil },
      "前提: レビューを開けて、diff の両端が揃う")
    hosted.pane.pullRequest.select(.file("b.swift"))
    pumpMain(until: { hosted.window.firstResponder === hosted.list }, "前提: 一覧に焦点")

    let up = String(UnicodeScalar(NSEvent.SpecialKey.upArrow.rawValue)!)
    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: .key(up)))
    XCTAssertTrue(review.isOpen, "ポップアップが開く")
    pumpMain(
      until: {
        self.messageField(in: hosted.pane.dockHost).map { hosted.window.firstResponder === $0 }
          ?? false
      }, "全体へのコメント欄に焦点が入る")

    let field = try XCTUnwrap(messageField(in: hosted.pane.dockHost))
    field.insertText("見ました", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: .key("\r")))
    pumpMain(until: { !review.isOpen }, "送信が通って閉じる")
    pumpMain(until: { hosted.window.firstResponder === hosted.list }, "焦点は一覧へ戻る")
    XCTAssertEqual(hosted.pane.pullRequest.selection, .file("b.swift"), "選択は開く前のまま")
  }
}
