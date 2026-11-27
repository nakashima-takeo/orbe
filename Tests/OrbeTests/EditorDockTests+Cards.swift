import AppKit
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 置き場の並び（`EditorDockStack`）と失敗の札（`EditorFailureCard`）——高さが足りないときの並び、札の幅と、札の × の働き。
///
/// 壊れると何が起きるか（`EditorDockTests` の説明に書いたことのほか）。短い失敗の札が置き場の幅いっぱいに広がり、札の左の
/// 本体が押せなくなる。本体の上端に帯がある間、ポップアップがバーから離れて開く。
extension EditorDockTests {
  /// 置き場の高さが足りなければ、札は全部が置き場の中に見え、ポップアップは札の残りの高さに縮む。
  func testTheCardsStayWholeAndThePopupShrinksWhenTheDockIsShort() throws {
    let height: CGFloat = 200
    let frames = Record<[CGRect]>([])
    let host = NSHostingView(
      rootView: EditorDockStack {
        // 中身は 400 まで伸び、それより低く求められれば縮む（入力欄が中でスクロールする中身）。
        Color.clear.frame(width: 300).frame(maxHeight: 400).editorDockItem()
      } cards: {
        EditorFailureCard(text: "コミットに失敗しました。", dismiss: {})
        EditorFailureCard(text: "プッシュに失敗しました。", dismiss: {})
      }
      .frame(width: Theme.Layout.editorDockWidth, height: height)
      .coordinateSpace(.named(EditorDockRoot.space))
      .onPreferenceChange(EditorDockFramesKey.self) { frames.value = $0 }
      .environment(\.localization, LocalizationStore(language: .ja)))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: Theme.Layout.editorDockWidth, height: height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    holdUntilTestEnds(window)
    host.layoutSubtreeIfNeeded()
    pumpMain(until: { frames.value.count == 3 }, "ポップアップと札 2 枚の枠")

    let popup = frames.value[0]
    let cards = Array(frames.value.dropFirst())
    let gap = Theme.Layout.editorDockGap
    XCTAssertEqual(popup.minY, 0, accuracy: 0.5)
    XCTAssertEqual(cards[0].minY, popup.maxY + gap, accuracy: 0.5, "札はポップアップの下")
    XCTAssertEqual(cards[1].minY, cards[0].maxY + gap, accuracy: 0.5)
    XCTAssertLessThanOrEqual(cards[1].maxY, height + 0.5, "札は全部が置き場の中")
    XCTAssertLessThan(popup.height, 400, "ポップアップが縮む")
  }

  /// 本体の上端に帯がある（`cardsTop` が 0 でない）間も、ポップアップは並びの上端（バーの下端）から開き、
  /// 札はポップアップの下に並ぶ。
  func testWithABandAboveTheBodyThePopupStillOpensAtTheTopAndTheCardsFollowIt() throws {
    let band: CGFloat = 32
    let frames = Record<[CGRect]>([])
    let host = NSHostingView(
      rootView: EditorDockStack(cardsTop: band) {
        Color.clear.frame(width: 300, height: 120).editorDockItem()
      } cards: {
        EditorFailureCard(text: "プッシュに失敗しました。", dismiss: {})
      }
      .frame(width: Theme.Layout.editorDockWidth, height: 400)
      .coordinateSpace(.named(EditorDockRoot.space))
      .onPreferenceChange(EditorDockFramesKey.self) { frames.value = $0 }
      .environment(\.localization, LocalizationStore(language: .ja)))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: Theme.Layout.editorDockWidth, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    holdUntilTestEnds(window)
    host.layoutSubtreeIfNeeded()
    pumpMain(until: { frames.value.count == 2 }, "ポップアップと札の枠")

    let popup = frames.value[0]
    let card = frames.value[1]
    XCTAssertEqual(popup.minY, 0, accuracy: 0.5, "ポップアップは上端から開く")
    XCTAssertEqual(
      card.minY, popup.maxY + Theme.Layout.editorDockGap, accuracy: 0.5, "札はポップアップの下")
  }

  /// 短い文の失敗の札は、文の幅だけを取って右に寄り、置き場が押下を受ける枠も、その幅だけ（札の左の空いた所は、下の
  /// 本体へ通る）。
  func testAShortFailureCardTakesOnlyTheWidthOfItsText() throws {
    let width = Theme.Layout.editorDockWidth
    let frames = Record<[CGRect]>([])
    let host = NSHostingView(
      rootView: EditorDockStack {
      } cards: {
        EditorFailureCard(text: "プッシュに失敗しました。", dismiss: {})
      }
      .frame(width: width, height: 200)
      .coordinateSpace(.named(EditorDockRoot.space))
      .onPreferenceChange(EditorDockFramesKey.self) { frames.value = $0 }
      .environment(\.localization, LocalizationStore(language: .ja)))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = host
    holdUntilTestEnds(window)
    host.layoutSubtreeIfNeeded()
    pumpMain(until: { frames.value.count == 1 }, "札の枠")

    let card = frames.value[0]
    XCTAssertLessThan(card.width, width / 2, "札は文の幅だけ")
    XCTAssertEqual(card.maxX, width, accuracy: 0.5, "札は右に寄る")
  }

  /// 失敗の札の × を押すと、渡した処理が呼ばれる。文の上の押下では呼ばれない。
  func testTheCloseButtonOfAFailureCardCallsTheGivenAction() throws {
    let width: CGFloat = 400
    let dismissed = Record(0)
    let host = NSHostingView(
      rootView: EditorFailureCard(
        text: "コミットに失敗しました: 競合が残っています。競合を解決し、そのファイルをステージしてからコミットしてください。",
        dismiss: { dismissed.value += 1 }
      )
      // 札は文の幅に合わせるので、折り返す長さの文で、札を幅いっぱいにする（置き場と同じく右寄せ）。
      .frame(width: width, alignment: .trailing)
      .environment(\.localization, LocalizationStore(language: .ja)))
    host.frame.size = NSSize(width: width, height: host.fittingSize.height)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    holdUntilTestEnds(window)
    placeOffscreen(window)
    host.layoutSubtreeIfNeeded()
    func click(_ point: NSPoint) throws {
      try self.click(host, at: point)
      flush(window)
    }
    // × は右上の角から余白 7 の内側に在る、20 角のボタン。
    let inset = Theme.Layout.editorCardClosePad + Theme.Layout.editorCardClose / 2
    let close = NSPoint(x: width - inset, y: host.isFlipped ? inset : host.bounds.maxY - inset)

    try click(NSPoint(x: 40, y: host.bounds.midY))
    XCTAssertEqual(dismissed.value, 0, "文の上の押下では呼ばれない")
    try click(close)
    XCTAssertEqual(dismissed.value, 1, "× で呼ばれる")
  }
}
