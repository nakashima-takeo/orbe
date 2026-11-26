import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 面に載せたレビューのポップアップ——PR の一覧の ⌘↑ は、選んでいる行に依らずポップアップを開き、全体へのコメント欄に焦点を
/// 入れ、送って閉じれば焦点は一覧へ戻る。開いたときの PR のまま知らせが届いても閉じず、PR が替われば閉じる。
///
/// 壊れると何が起きるか: 一覧でファイルを見ながらマウスを使わずにレビューを書き始められない。先頭より下の行を選んでいると
/// ⌘↑ が効かない。開いても欄に焦点が入らず、打鍵が一覧へ入る。送った後に焦点が本文へ移り、↑↓ で続けてファイルを見られない。
/// 面を隠している間に PR が替わった後、チェックを付けるたびにポップアップが閉じて、変換中の字が確定する。ブランチを
/// 切り替えても前の PR のポップアップが開いたまま残り、前の PR の書きかけを次の PR に送る。
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

  /// 面を隠している間に、ほかの面が今の PR の替わりを受けても、出し直した後に開いたポップアップは、同じ PR の知らせでは
  /// 閉じず、全体へのコメント欄の変換中の字も確定しない。その後に PR が替われば、その知らせで閉じる。
  func testAReviewOpenedAfterAChangeWhileHiddenClosesOnlyWhenThePullRequestChangesAgain() throws {
    let root = try registeredRoot()
    let hosted = host(root)
    shownWithRows(hosted)
    let other = host(root)
    shownWithRows(other)
    let previous = try XCTUnwrap(hosted.pane.pullRequest.state)
    hosted.tab.group.view.show(.terminal, animated: false)
    gitHub.number = 10
    other.pane.pullRequest.refresh()
    pumpMain(
      until: { other.pane.pullRequest.state.map { $0 !== previous && $0.review != nil } ?? false },
      "前提: ほかの面が次の PR を見る")
    hosted.tab.group.view.show(.editor, animated: false)
    let field = try openReview(hosted)
    let review = hosted.pane.reviewPopup
    let state = try XCTUnwrap(hosted.pane.pullRequest.state)
    XCTAssertTrue(state !== previous, "前提: 次の PR で開く")
    field.setMarkedText(
      "かきかけ", selectedRange: NSRange(location: 4, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))

    hosted.pane.pullRequest.toggleViewed("b.swift")
    XCTAssertTrue(state.isViewed("b.swift"), "前提: 同じ PR の知らせ")
    XCTAssertTrue(review.isOpen, "同じ PR の知らせでは閉じない")
    XCTAssertTrue(field.hasMarkedText(), "変換中の字を確定しない")
    XCTAssertEqual(state.reviewDraft.body, "")

    gitHub.number = 11
    hosted.pane.pullRequest.refresh()
    pumpMain(
      until: { hosted.pane.pullRequest.state.map { $0 !== state } ?? false }, "前提: PR が替わる")
    XCTAssertFalse(review.isOpen, "PR が替わった知らせで閉じる")
  }
}
