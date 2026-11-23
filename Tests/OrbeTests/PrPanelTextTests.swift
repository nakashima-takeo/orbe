import XCTest

@testable import Orbe

/// PR のパネルの文——手元とのずれの帯と、gh の失敗の文。
///
/// 壊れると何が起きるか: 未 push だけなのに「未取得 0 件」まで並ぶ。gh が理由を返さなかった書き込みの失敗が、読み込みの
/// 失敗の文で出る。時間切れの書き込みの失敗の文が、GitHub に届いていたかもしれないことを告げず、送り直した同じコメントが
/// 二重に付く。
@MainActor
final class PrPanelTextTests: OrbeTestCase {
  private let l10n = LocalizationStore(language: .ja)

  /// 数えられたずれは、0 の側を出さず、両方あれば未 push・未取得の順に「・」でつなぐ。
  func testTheDriftBandOmitsTheZeroSideAndJoinsBoth() {
    let unpushed = l10n.format(.editorPrUnpushed, 2)
    let unfetched = l10n.format(.editorPrUnfetched, 3)
    XCTAssertEqual(PrPanelText.drift(.diverged(ahead: 2, behind: 0), l10n), unpushed)
    XCTAssertEqual(PrPanelText.drift(.diverged(ahead: 0, behind: 3), l10n), unfetched)
    XCTAssertEqual(
      PrPanelText.drift(.diverged(ahead: 2, behind: 3), l10n), unpushed + "・" + unfetched)
  }

  /// gh が理由を返さなかった失敗は、読み込みと書き込みで決まった文が違う。理由があればその文。
  func testAnEmptyReasonSaysWhetherTheReadOrTheWriteFailed() {
    XCTAssertEqual(
      PrPanelText.contentFailure(.reason(""), l10n), l10n.string(.editorPrFailedRead))
    XCTAssertEqual(
      PrPanelText.viewedFailure(.reason(""), l10n), l10n.string(.editorPrFailedWrite))
    XCTAssertEqual(PrPanelText.viewedFailure(.reason("denied"), l10n), "denied")
  }

  /// レビューへの書き込みの時間切れでは、届いていたかもしれないことを告げる文が出て、ほかの書き込みの失敗の文と違う。
  func testATimedOutReviewWriteSaysItMayHaveReachedGitHub() {
    XCTAssertEqual(
      PrPanelText.writeFailure(.timedOut, .ja), l10n.string(.editorPrWriteTimedOut))
    XCTAssertEqual(
      PrPanelText.writeFailure(.reason(""), .ja), l10n.string(.editorPrFailedWrite))
  }
}
