import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 面に載せたレビューのポップアップ——PR の一覧の ⌘↑ は、選んでいる行に依らずポップアップを開き、全体へのコメント欄に焦点を
/// 入れ、送って閉じれば焦点は一覧へ戻る。開いたときの PR のまま知らせが届いても、失敗の札が出入りしても閉じず、PR が替わるか
/// open でなくなれば閉じる（open でない PR へは送れない）。書きかけは閉じても残り、開き直した欄はそこから始まる。欄の esc は
/// 変換中でなければ閉じ、その後に押し続けて届いた esc は、戻った一覧に届かない。
///
/// 壊れると何が起きるか: 一覧でファイルを見ながらマウスを使わずにレビューを書き始められない。先頭より下の行を選んでいると
/// ⌘↑ が効かない。開いても欄に焦点が入らず、打鍵が一覧へ入る。送った後に焦点が本文へ移り、↑↓ で続けてファイルを見られない。
/// 面を隠している間に PR が替わった後、チェックを付けるたびにポップアップが閉じて、変換中の字が確定する。失敗の札が出入り
/// するたびに欄が作り直され、打った字と焦点が消える。閉じて開き直すと書きかけが消えている。esc で閉じられない・変換を
/// 取り消すつもりの esc でポップアップが閉じる・esc を押し続けると戻った一覧の選択が外れる。ブランチを切り替えても前の PR の
/// ポップアップが開いたまま残り、前の PR の書きかけを次の PR に送る。マージ・クローズの後もポップアップが残り、⌘↵ で送れる。
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

  /// 開いている間に失敗の札が出ても消えても（置き場が組み直されても）、ポップアップは閉じず、全体へのコメント欄は同じ欄の
  /// まま、焦点も変換中の字も残る。
  func testTheReviewFieldLastsWhileAFailureCardComesAndGoes() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    let field = try openReview(hosted)
    let review = hosted.pane.reviewPopup
    let state = try XCTUnwrap(hosted.pane.pullRequest.state)
    let dock = hosted.pane.dockHost
    field.setMarkedText(
      "かきかけ", selectedRange: NSRange(location: 4, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    pumpMain(until: { dock.itemFrames.count == 1 }, "前提: 置き場にはポップアップだけ")

    for (fails, cards) in [(true, 1), (false, 0)] {
      gitHub.contentFails = fails
      state.reload()
      pumpMain(until: { (state.contentFailure != nil) == fails }, "前提: 中身の読みの答えが届く")
      pumpMain(until: { dock.itemFrames.count == 1 + cards }, "前提: 札が \(cards) 枚")
      nextTurn()
      XCTAssertTrue(review.isOpen, "札が \(cards) 枚: ポップアップは開いたまま")
      XCTAssertTrue(messageField(in: dock) === field, "札が \(cards) 枚: 欄は同じ欄のまま")
      XCTAssertTrue(hosted.window.firstResponder === field, "札が \(cards) 枚: 焦点は欄に残る")
      XCTAssertTrue(field.hasMarkedText(), "札が \(cards) 枚: 変換中の字が残る")
    }
  }

  /// 変換中の esc では閉じない。閉じても書きかけは残り（変換中の字は確定して入る）、開き直した全体へのコメント欄は新しい欄で、
  /// 書きかけから始まる。欄の esc で閉じると、焦点は開く前に在った一覧へ戻り、その後に押し続けて届いた esc は、押し続けでない
  /// 打鍵が来るまで捨てる。
  func testAReopenedReviewStartsAFreshFieldFromTheDraftAndEscapeClosesIt() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    let first = try openReview(hosted)
    let review = hosted.pane.reviewPopup
    let state = try XCTUnwrap(hosted.pane.pullRequest.state)
    let escape = { (isRepeat: Bool) in
      self.deliverKeyDown(.key("\u{1b}", [], isRepeat: isRepeat), to: hosted.window)
    }
    first.insertText("前の", replacementRange: NSRange(location: NSNotFound, length: 0))
    first.setMarkedText(
      "かきかけ", selectedRange: NSRange(location: 4, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    escape(false)
    XCTAssertTrue(review.isOpen, "変換中の esc では閉じない")
    XCTAssertTrue(first.hasMarkedText(), "前提: 変換中のまま")
    review.toggle()
    XCTAssertFalse(review.isOpen, "前提: 「レビュー」のボタンを押したときと同じ口で閉じる")
    XCTAssertEqual(state.reviewDraft.body, "前のかきかけ", "変換中の字は確定して書きかけに入る")

    let second = try openReview(hosted)
    XCTAssertFalse(second === first, "開き直した欄は新しい欄")
    XCTAssertEqual(second.string, "前のかきかけ", "書きかけから始まる")
    XCTAssertFalse(second.hasMarkedText())

    escape(false)
    XCTAssertFalse(review.isOpen, "esc で閉じる")
    pumpMain(until: { hosted.window.firstResponder === hosted.list }, "焦点は一覧へ戻る")
    XCTAssertEqual(state.reviewDraft.body, "前のかきかけ", "esc で閉じても書きかけは残る")
    // 押し続けた esc を捨てるのは窓のイベントの監視で、テストから窓へ送るキーはそこを通らないので、監視の判定を見る。
    let repeated = NSEvent.key("\u{1b}", [], isRepeat: true)
    XCTAssertTrue(hosted.pane.escapeRepeatIsSwallowed(repeated), "押し続けて届いた esc は捨てる")
    XCTAssertFalse(hosted.pane.escapeRepeatIsSwallowed(.key("j", [])), "前提: 押し続けでない打鍵は届く")
    XCTAssertFalse(hosted.pane.escapeRepeatIsSwallowed(repeated), "押し続けでない打鍵の後は捨てない")
  }

  /// 開いている間に PR が open でなくなる（マージされた）と、ポップアップは閉じ、開き直せず、送れない。
  func testAReviewClosesAndCannotBeSentOnceThePullRequestIsNoLongerOpen() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    let field = try openReview(hosted)
    let review = hosted.pane.reviewPopup
    let state = try XCTUnwrap(hosted.pane.pullRequest.state)
    field.insertText("見ました", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(review.canSubmit, "前提: 送れる")

    gitHub.state = .merged
    state.reload()
    pumpMain(until: { state.content?.state == .merged }, "前提: マージされたと読む")
    XCTAssertFalse(review.isOpen, "閉じる")
    review.requestOpen()
    XCTAssertFalse(review.isOpen, "開き直せない")
    XCTAssertFalse(state.canSubmitReview(composing: ""), "送れない")
    XCTAssertFalse(state.submitReview { _ in }, "送信を受け付けない")
    XCTAssertEqual(gitHub.reviewWrites, [])
  }
}
