import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR の画面の失敗の札（`PrFailureCards`）——GitHub から読めていないときの札は 3 つの読みの失敗で 1 枚。× で閉じた印は札の単位で、
/// どの読みも通るか、人が再読込を頼むまで残り、その間は自動の読み直しの失敗でも別の読みの初めての失敗でも出直さない。確認済みの
/// 札は読みが通っても残り、× で消える。送信の失敗は、レビューのポップアップが開いていればポップアップの中だけに出て、閉じて
/// いれば札に出る。ポップアップを閉じても消えず、札の × で消える。
///
/// 壊れると何が起きるか: ネットワークが切れると札が何枚も重なる。× で閉じた札が、前面に戻るたびの読み直しや、別の読みの失敗で
/// 出直す。再読込を押して失敗しても札が出ない。読めるようになった後の失敗で札が出ない。読めるようになっても札が残る。確認済みを
/// 反映できなかった札が、次の読み直しで見る前に消える。送信中に閉じたポップアップの送信の失敗に気づけない。ポップアップの中の
/// 帯と札に同じ失敗が二重に出る。時間切れの後にポップアップを閉じると警告が消え、同じレビューを警告なしに送り直せる。
extension PrPanelTests {
  /// 今の札の種類（上から）。
  private func cardKinds(reviewIsOpen: Bool = false) -> [PrFailureCard.Kind] {
    cards(reviewIsOpen: reviewIsOpen).map(\.kind)
  }

  private func cards(reviewIsOpen: Bool = false) -> [PrFailureCard] {
    PrFailureCards.cards(
      of: panel.pullRequest, reviewIsOpen: reviewIsOpen, LocalizationStore(language: .ja))
  }

  /// 3 つの読み（今のブランチの PR の引き直し・中身・レビューのやりとり）が `reason` で失敗するまで待つ。
  private func waitForReadFailures(_ reason: GitHubFailure, _ message: String) {
    let state = panel.state
    pumpMain(
      until: {
        state?.contentFailure == reason && state?.reviewFailure == reason
          && self.panel.pullRequest.lookupFailure == .failed(reason)
      }, message)
  }

  /// GitHub から読めない間、札は 1 枚。× で閉じると、自動の読み直しが失敗しても出直さず、再読込を頼んで失敗すると出る。読めれば、
  /// 閉じていなくても消える。
  func testReadingFailuresShowOneCardThatStaysClosedUntilAReloadIsAsked() throws {
    let state = try reviewed()
    readFailure = .unreachable
    panel.refresh()
    waitForReadFailures(.unreachable, "前提: 3 つの読みが失敗する")
    XCTAssertEqual(cardKinds(), [.reading], "読みの失敗が 3 つでも札は 1 枚")

    try XCTUnwrap(cards().first).dismiss()
    XCTAssertEqual(cardKinds(), [], "× で閉じる")
    readFailure = .rateLimited
    panel.pullRequest.reload()
    state.reload()
    waitForReadFailures(.rateLimited, "前提: 自動の読み直しも失敗する")
    XCTAssertEqual(cardKinds(), [], "自動の読み直しの失敗では出直さない")

    readFailure = .unreachable
    panel.refresh()
    waitForReadFailures(.unreachable, "前提: 頼んだ再読込が失敗する")
    XCTAssertEqual(cardKinds(), [.reading], "頼んだ再読込が失敗すれば出る")

    readFailure = nil
    panel.refresh()
    pumpMain(
      until: {
        state.contentFailure == nil && state.reviewFailure == nil
          && self.panel.pullRequest.lookupFailure == nil
      }, "読めるようになる")
    XCTAssertEqual(cardKinds(), [], "閉じていなくても消える")
  }

  /// 閉じた印は札の単位——一部の読みだけが失敗しているときに閉じると、別の読みが後から初めて失敗しても出直さない。3 つの読みが
  /// どれも失敗していない状態になれば印は外れ、次に読みが失敗すると、再読込を頼まなくても出る。
  func testTheReadingCardStaysClosedUntilEveryReadSucceeds() throws {
    let state = try reviewed()
    reviewReadFailure = .unreachable
    state.reload()
    pumpMain(until: { state.reviewFailure != nil }, "前提: レビューのやりとりの読みだけが失敗する")
    XCTAssertNil(state.contentFailure, "前提: 中身は読める")
    try XCTUnwrap(cards().first).dismiss()
    XCTAssertEqual(cardKinds(), [], "× で閉じる")

    readFailure = .rateLimited
    state.reload()
    pumpMain(until: { state.contentFailure != nil }, "前提: 中身の読みが初めて失敗する")
    XCTAssertEqual(cardKinds(), [], "別の読みが初めて失敗しても出直さない")

    readFailure = nil
    reviewReadFailure = nil
    state.reload()
    pumpMain(
      until: { state.contentFailure == nil && state.reviewFailure == nil }, "前提: どの読みも通る")
    reviewReadFailure = .unreachable
    state.reload()
    pumpMain(until: { state.reviewFailure != nil }, "前提: また読みが失敗する")
    XCTAssertEqual(cardKinds(), [.reading], "読めた後の失敗は、再読込を頼まなくても出る")
  }

  /// 確認済みの書き込みの失敗の札は、続く読みが通っても残り、× で消える。もう一度付け外しして通らなければ、また出る。
  func testAViewedFailureCardOutlivesReadsUntilItIsClosed() throws {
    let state = try reviewed()
    viewedFailure = .rateLimited
    panel.toggleViewed("README.md")
    pumpMain(until: { state.viewedFailure != nil }, "前提: 確認済みの書き込みが失敗する")
    XCTAssertEqual(cardKinds(), [.viewed])

    // 読みが通ったことを、失敗の後の読みで見る。
    readFailure = .unreachable
    state.reload()
    pumpMain(
      until: { state.contentFailure != nil && state.reviewFailure != nil }, "前提: 読みが失敗する")
    readFailure = nil
    state.reload()
    pumpMain(
      until: { state.contentFailure == nil && state.reviewFailure == nil }, "前提: 読みが通る")
    XCTAssertEqual(cardKinds(), [.viewed], "読みが通っても残る")
    try XCTUnwrap(cards().first).dismiss()
    XCTAssertEqual(cardKinds(), [], "× で消える")

    panel.toggleViewed("README.md")
    pumpMain(until: { state.viewedFailure != nil }, "もう一度の書き込みも失敗する")
    XCTAssertEqual(cardKinds(), [.viewed], "また出る")
  }

  /// ポップアップを開いたまま送信が失敗すると、ポップアップは開いたままで札は出ない。送信中に閉じたポップアップの送信が失敗すると
  /// 札に出て、ポップアップを開くと札からは消える。どちらも、ポップアップを閉じると札に戻る。
  func testASubmissionFailureShowsInTheOpenPopupOrElseAsACard() throws {
    let state = try reviewed()
    let popup = EditorPopup()
    let review = PrReviewPopup(pullRequest: panel.pullRequest, popup: popup)
    state.reviewDraft.body = "見ました"
    reviewFailure = .unreachable
    review.requestOpen()
    XCTAssertTrue(review.submit(), "前提: 送れる")
    pumpMain(until: { state.submissionFailure != nil }, "前提: 送信が失敗する")
    XCTAssertTrue(review.isOpen, "開いたまま")
    XCTAssertEqual(cardKinds(reviewIsOpen: review.isOpen), [], "開いている間は札に出さない")
    popup.close(.escape)
    XCTAssertNotNil(state.submissionFailure, "閉じても消えない")
    XCTAssertEqual(cardKinds(reviewIsOpen: review.isOpen), [.submission], "閉じると札に出る")
    try XCTUnwrap(cards().first { $0.kind == .submission }).dismiss()
    XCTAssertNil(state.submissionFailure, "× で消える")

    review.requestOpen()
    holdsReviewWrites = true
    XCTAssertTrue(review.submit(), "前提: 送れる")
    popup.close(.escape)
    for answer in heldReviewWrites { answer() }
    pumpMain(until: { state.submissionFailure != nil }, "前提: 閉じた後に送信が失敗する")
    XCTAssertEqual(cardKinds(reviewIsOpen: review.isOpen), [.submission], "閉じていれば札に出る")
    review.requestOpen()
    XCTAssertEqual(cardKinds(reviewIsOpen: review.isOpen), [], "開くと札からは消える")
    popup.close(.escape)
    XCTAssertEqual(cardKinds(reviewIsOpen: review.isOpen), [.submission], "閉じると札に戻る")
  }
}
