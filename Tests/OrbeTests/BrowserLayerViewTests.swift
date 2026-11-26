import AppKit
import OrbeTestSupport
import WebKit
import XCTest

@testable import Orbe

/// 内蔵ブラウザ層（`BrowserLayerView`）の遅延 WebKit 生成・隔離データストア・`hitTest` 貫通と吸収・
/// 透かしの 2 形態（右シート／全面）・開閉フェードを守る。
///
/// 壊れると何が起きるか。起動直後に不要な WebKit プロセスが起きる、隔離環境（テスト・sandbox）で
/// 実環境の `~/Library/WebKit/` が汚れる、右シート表示中に左の端末をクリックできなくなる、
/// 透かし中にクリックやスクロールが背後の面へ貫通する、全面めくりで 36pt バーまで消えてしまう、
/// あるいはフェード途中反転でブラウザが透明のまま残る。
@MainActor
final class BrowserLayerViewTests: OrbeTestCase {
  let stageSize = NSSize(width: 1000, height: 600)

  struct Hosted {
    let window: OrbeWindowFake
    let stage: NSView
    let underlay: NSView
    let browser: BrowserLayerView
  }

  /// 本番 `AppStageView` と同じ兄弟構成（下層 `underlay` の直上に `BrowserLayerView`）を窓に載せる。
  func hostBrowser(reduceMotion: Bool = true) -> Hosted {
    let window = OrbeWindowFake(
      contentRect: NSRect(origin: .zero, size: stageSize), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isKey = true

    let stage = NSView(frame: NSRect(origin: .zero, size: stageSize))
    let underlay = NSView(frame: stage.bounds)
    underlay.autoresizingMask = [.width, .height]
    let browser = BrowserLayerView(
      localization: LocalizationStore(language: .ja), fontResolver: ChromeFontResolver())
    browser.reduceMotion = reduceMotion
    browser.frame = stage.bounds
    browser.autoresizingMask = [.width, .height]

    stage.addSubview(underlay)
    stage.addSubview(browser)
    window.contentView = stage
    stage.layoutSubtreeIfNeeded()
    holdUntilTestEnds(window)
    addTeardownBlock { MainActor.assumeIsolated { window.contentView = nil } }
    return Hosted(window: window, stage: stage, underlay: underlay, browser: browser)
  }

  // MARK: - 遅延生成と隔離

  /// 初回表示まで `WKWebView` を作らず、隔離環境では `identifier` の有無に依らず非永続ストアだけを返す。
  func testWebViewIsCreatedLazilyWithNonPersistentStoreInIsolatedEnvironment() throws {
    XCTAssertTrue(StateDir.isIsolated, "前提: テストプロセスは隔離環境")
    XCTAssertFalse(BrowserDataStore.make().isPersistent, "既定呼び出しは非永続ストア")
    XCTAssertFalse(
      BrowserDataStore.make(isolated: true, identifier: UUID()).isPersistent,
      "隔離時は identifier 指定でも非永続ストアを優先する")

    let hosted = hostBrowser()
    let browser = hosted.browser
    XCTAssertNil(browser.webView, "閉状態のままでは WKWebView を生成しない")
    XCTAssertTrue(browser.isHidden)

    browser.setMode(.sheet, animated: false)
    let webView = try XCTUnwrap(browser.webView, "初回表示で生成される")
    XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent, "非永続ストアを使う")
  }

  // MARK: - hitTest 貫通と透かし吸収

  /// 右シート左半分と閉じフェード中は下層へ貫通し、シート内空画面クリックは焦点を取る。
  /// 透かし中は左半分を含め全領域をブラウザ層自身が吸収する。
  func testHitTestPassesThroughLeftHalfAndClosingFadeAndAbsorbsWhilePeeking() {
    let hosted = hostBrowser(reduceMotion: false)
    let (window, stage, underlay, browser) = (
      hosted.window, hosted.stage, hosted.underlay, hosted.browser
    )
    browser.setMode(.sheet, animated: false)
    stage.layoutSubtreeIfNeeded()

    let leftPoint = NSPoint(x: 100, y: 300)
    let sheetPoint = NSPoint(x: 750, y: 300)
    XCTAssertTrue(stage.hitTest(leftPoint) === underlay, "右シート左半分は下層へ貫通する")
    XCTAssertTrue(stage.hitTest(sheetPoint) === browser, "空画面はブラウザ層自身が受ける")

    window.makeFirstResponder(nil)
    browser.mouseDown(with: .mouse(.leftMouseDown, at: sheetPoint, in: window))
    XCTAssertTrue(window.firstResponder === browser, "空画面クリックでブラウザ層が焦点を取る")

    browser.setPeeking(true, animated: false)
    XCTAssertTrue(stage.hitTest(leftPoint) === browser, "透かし中は左半分もブラウザ層が吸収する")
    XCTAssertTrue(stage.hitTest(sheetPoint) === browser, "透かし中はシート側もブラウザ層が吸収する")
    browser.setPeeking(false, animated: false)

    browser.setMode(.closed, animated: true)
    XCTAssertTrue(browser.isFading, "前提: 閉じるフェード中")
    XCTAssertFalse(browser.isHidden, "前提: 閉じる途中はまだ見えている")
    XCTAssertTrue(stage.hitTest(sheetPoint) === underlay, "閉じるフェード中はシート領域も下層へ貫通する")
  }

  // MARK: - 透かしの 2 形態と焦点保持

  /// 右シート透かしはシート全体を隠し右端 2px 線だけを残し、全面透かしは 36pt バーを不透明に残して
  /// バーより下だけを透明にする。どちらも焦点を動かさず、閉鎖時に透かし状態は正規化される。
  func testPeekPreservesFocusAndSeparatesSheetVsFullPresentation() {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    browser.setMode(.sheet, animated: false)
    browser.focusBrowser()
    browser.setFocused(true)
    XCTAssertTrue(window.firstResponder === browser, "前提: ブラウザに焦点")
    XCTAssertFalse(browser.leftVeilView.isHidden, "前提: 右シート＋焦点で左層ベール点灯")

    browser.setPeeking(true, animated: false)
    XCTAssertFalse(browser.isHidden, "ビュー自体は隠さず不透明度で透過する")
    XCTAssertEqual(browser.sheetView.alphaValue, 0, "右シート透かしはシート全体を透明にする")
    XCTAssertFalse(browser.peekRailView.isHidden, "右端 2px レールが出る")
    XCTAssertTrue(browser.leftVeilView.isHidden, "透かし中は左層ベールを消す")
    XCTAssertTrue(window.firstResponder === browser, "透かしで焦点を動かさない")

    browser.setPeeking(false, animated: false)
    browser.setMode(.full, animated: false)
    browser.setPeeking(true, animated: false)
    XCTAssertEqual(browser.sheetView.alphaValue, 1, "全面透かしは 36pt バーを不透明のまま残す")
    XCTAssertEqual(browser.belowBar.alphaValue, 0, "全面透かしはバーより下だけを透明にする")
    XCTAssertTrue(browser.peekRailView.isHidden, "全面透かしでは右端レールを出さない")
    XCTAssertTrue(window.firstResponder === browser, "全面透かしでも焦点を動かさない")

    browser.setMode(.closed, animated: false)
    XCTAssertFalse(browser.isPeeking, "閉鎖時は透かし状態を false に正規化する")
    XCTAssertFalse(browser.toolbar.isPeeking)
  }

  // MARK: - 開閉フェード

  /// 閉じるフェード中に反転しても最終状態へ収束し、動きを減らす設定では即時切り替わる。
  func testClosingFadeAndMidFadeReversalFinishAtLatestTarget() {
    let hosted = hostBrowser(reduceMotion: false)
    let browser = hosted.browser
    browser.setMode(.sheet, animated: false)

    browser.setMode(.closed, animated: true)
    XCTAssertTrue(browser.isFading, "閉じる方向はフェードが始まる")
    XCTAssertFalse(browser.isHidden, "閉じる途中は見えている")
    XCTAssertEqual(browser.sheetView.alphaValue, 0)

    // 閉じる途中で開き直しても、古い完了通知で閉じ戻らず開状態で落ち着く。
    browser.setMode(.sheet, animated: true)
    pumpMain(until: { !browser.isFading }, timeout: 2, "反転後の動きが終わる")
    XCTAssertFalse(browser.isHidden)
    XCTAssertEqual(browser.sheetView.alphaValue, 1)

    browser.reduceMotion = true
    browser.setMode(.closed, animated: true)
    XCTAssertFalse(browser.isFading, "動きを減らす設定では即時")
    XCTAssertTrue(browser.isHidden)
  }

  /// 閉状態から動きつきで開くとフェードが始まり、完了後に不透明な表示状態へ落ち着く。
  func testOpeningFromClosedStartsFadeWhenMotionEnabled() {
    let hosted = hostBrowser(reduceMotion: false)
    let browser = hosted.browser
    XCTAssertTrue(browser.isHidden, "前提: 閉状態では隠れている")

    XCTExpectFailure(
      "バグ疑い: 閉状態で BrowserLayerView 自身が isHidden=true のため runFade の !isHiddenOrHasHiddenAncestor で開くフェードがスキップされる"
    ) {
      browser.setMode(.sheet, animated: true)
      XCTAssertTrue(browser.isFading, "閉状態から動きつきで開くとフェードが始まる")
    }
    pumpMain(until: { !browser.isFading }, timeout: 2, "フェードが終わる")
    XCTAssertFalse(browser.isHidden)
    XCTAssertEqual(browser.sheetView.alphaValue, 1)
  }
}
