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

  /// 閉状態およびタブ 0 枚の空画面では `WKWebView` を作らず、遷移要求で初めて遅延生成する。
  /// 隔離環境ではプロファイル UUID ごとに独立した非永続ストアを共有し、永続ストアへ触れない。
  func testWebViewIsCreatedLazilyWithNonPersistentStoreInIsolatedEnvironment() throws {
    XCTAssertTrue(StateDir.isIsolated, "前提: テストプロセスは隔離環境")
    let registry = BrowserDataStoreRegistry()
    let profileA = UUID()
    let profileB = UUID()
    let storeA1 = registry.store(for: profileA)
    let storeA2 = registry.store(for: profileA)
    let storeB = registry.store(for: profileB)
    XCTAssertFalse(storeA1.isPersistent, "隔離環境では非永続ストアを返す")
    XCTAssertFalse(storeB.isPersistent, "別プロファイルも非永続ストアを返す")
    XCTAssertTrue(storeA1 === storeA2, "同一プロファイルは同じ非永続ストアを共有する")
    XCTAssertFalse(storeA1 === storeB, "異なるプロファイルは別の非永続ストアへ分離する")

    let hosted = hostBrowser()
    let browser = hosted.browser
    XCTAssertNil(browser.webView, "閉状態のままでは WKWebView を生成しない")
    XCTAssertTrue(browser.sheetView.isHidden)

    browser.setMode(.sheet, animated: false)
    XCTAssertNil(browser.webView, "タブ 0 枚の空画面では WKWebView を生成しない")
    XCTAssertFalse(browser.emptyOverlay.isHidden)

    browser.loadHTMLString("<p>lazy</p>", baseURL: URL(string: "https://docs.orbe.dev/lazy"))
    let webView = try XCTUnwrap(browser.webView, "遷移要求で初めて遅延生成される")
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
    XCTAssertFalse(browser.sheetView.isHidden, "前提: 閉じる途中はまだ見えている")
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
    XCTAssertFalse(browser.sheetView.isHiddenOrHasHiddenAncestor, "ビュー自体は隠さず不透明度で透過する")
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

  /// 開く途中で閉じへ反転しても置き換えられた動きの完了で途中非表示にならず、最後の閉じフェード完走後に
  /// 非表示へ収束する。閉じる途中の反転と動きを減らす設定での即時切替も守る。
  func testClosingFadeAndMidFadeReversalFinishAtLatestTarget() {
    let hosted = hostBrowser(reduceMotion: false)
    let browser = hosted.browser

    // 開→閉の途中反転: 古い開きフェードの完了通知（世代違い）で途中非表示にならない。
    browser.setMode(.sheet, animated: true)
    XCTAssertTrue(browser.isFading, "開く方向はフェードが始まる")
    XCTAssertFalse(browser.sheetView.isHidden)
    XCTAssertEqual(browser.sheetView.alphaValue, 1)

    browser.setMode(.closed, animated: true)
    XCTAssertTrue(
      holds(for: Theme.Motion.base / 6) { !browser.sheetView.isHidden },
      "置き換えられた動きの完了では途中非表示にならない")
    XCTAssertEqual(browser.sheetView.alphaValue, 0)

    pumpMain(until: { !browser.isFading }, timeout: 2, "閉じフェードが完走する")
    XCTAssertTrue(browser.sheetView.isHidden, "閉じフェード完走後に非表示になる")

    // 閉→開の途中反転: 開状態で落ち着く。
    browser.setMode(.sheet, animated: false)
    browser.setMode(.closed, animated: true)
    browser.setMode(.sheet, animated: true)
    pumpMain(until: { !browser.isFading }, timeout: 2, "反転後の動きが終わる")
    XCTAssertFalse(browser.sheetView.isHidden)
    XCTAssertEqual(browser.sheetView.alphaValue, 1)

    browser.reduceMotion = true
    browser.setMode(.closed, animated: true)
    XCTAssertFalse(browser.isFading, "動きを減らす設定では即時")
    XCTAssertTrue(browser.sheetView.isHidden)
  }

  /// 全面表示や右投げ閉じプレビューからのアニメーション付き閉鎖フェード中は、閉鎖直前の幅を保ったまま
  /// フェードアウトし（`sheetRatio` へ瞬間縮小・拡大しない）、完走後に非表示になる。
  func testClosingFadePreservesPreCloseWidthFromFullAndRightThrow() {
    let hosted = hostBrowser(reduceMotion: false)
    let browser = hosted.browser
    browser.onRequestModeChange = { mode, animated in
      browser.setMode(mode, animated: animated)
    }

    // 全面（1000pt）からの閉鎖フェード中は全幅 1000pt のままフェードする。
    browser.setMode(.full, animated: false)
    hosted.stage.layoutSubtreeIfNeeded()
    XCTAssertEqual(browser.sheetView.frame.width, stageSize.width, accuracy: 0.5)

    browser.setMode(.closed, animated: true)
    XCTAssertTrue(browser.isFading)
    XCTAssertEqual(
      browser.sheetView.frame.width, stageSize.width, accuracy: 0.5,
      "全面からの閉鎖フェード中に右シート幅へ瞬間縮小しない")
    pumpMain(until: { !browser.isFading }, timeout: 2, "全面閉鎖フェードが終わる")
    XCTAssertTrue(browser.sheetView.isHidden)

    // 右投げ閉じプレビュー（180pt）からの閉鎖フェード中は 180pt のままフェードし、次回開くと元の 60% へ戻る。
    browser.setSheetRatio(0.60)
    browser.setMode(.sheet, animated: false)
    hosted.stage.layoutSubtreeIfNeeded()
    let handle = browser.resizeHandle
    let startPoint = browser.convert(NSPoint(x: browser.sheetView.frame.minX + 4, y: 200), to: nil)
    let throwPoint = browser.convert(NSPoint(x: 820, y: 200), to: nil)
    handle.mouseDown(with: .mouse(.leftMouseDown, at: startPoint, in: hosted.window))
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: throwPoint, in: hosted.window))
    XCTAssertEqual(browser.sheetView.frame.width, 180, accuracy: 0.5, "前提: 閉じプレビュー幅 180pt")
    handle.mouseUp(with: .mouse(.leftMouseUp, at: throwPoint, in: hosted.window))

    XCTAssertTrue(browser.isFading)
    XCTAssertEqual(
      browser.sheetView.frame.width, 180, accuracy: 0.5,
      "右投げ閉じフェード中に元の幅 600pt へ瞬間拡大しない")
    pumpMain(until: { !browser.isFading }, timeout: 2, "右投げ閉じフェードが終わる")
    XCTAssertTrue(browser.sheetView.isHidden)

    browser.setMode(.sheet, animated: false)
    XCTAssertEqual(browser.sheetView.frame.width, 600, accuracy: 0.5, "次回開くと開始前比率 60% へ戻る")
  }

  /// 閉状態から動きつきで開くと右シート・全面ともフェードが始まり、完了後に不透明な表示状態へ落ち着く。
  /// 祖先が隠れているときはフェードせず即時切り替わる。
  func testOpeningFromClosedStartsFadeWhenMotionEnabled() {
    let hosted = hostBrowser(reduceMotion: false)
    let (stage, underlay, browser) = (hosted.stage, hosted.underlay, hosted.browser)
    XCTAssertTrue(browser.sheetView.isHidden, "前提: 閉状態ではシートが隠れている")
    XCTAssertTrue(browser.leftVeilView.isHidden)
    XCTAssertTrue(browser.peekRailView.isHidden)
    XCTAssertTrue(stage.hitTest(NSPoint(x: 750, y: 300)) === underlay, "閉状態は下層へ貫通する")

    browser.setMode(.sheet, animated: true)
    XCTAssertTrue(browser.isFading, "閉状態から動きつきで開くとフェードが始まる")
    XCTAssertFalse(browser.sheetView.isHidden)
    pumpMain(until: { !browser.isFading }, timeout: 2, "フェードが終わる")
    XCTAssertFalse(browser.sheetView.isHidden)
    XCTAssertEqual(browser.sheetView.alphaValue, 1)

    browser.setMode(.closed, animated: false)
    XCTAssertTrue(browser.sheetView.isHidden)
    browser.setMode(.full, animated: true)
    XCTAssertTrue(browser.isFading, "閉状態から全面へ開くときもフェードが始まる")
    pumpMain(until: { !browser.isFading }, timeout: 2, "全面フェードが終わる")
    XCTAssertFalse(browser.sheetView.isHidden)
    XCTAssertEqual(browser.sheetView.alphaValue, 1)

    browser.setMode(.closed, animated: false)
    stage.isHidden = true
    browser.setMode(.sheet, animated: true)
    XCTAssertFalse(browser.isFading, "祖先が隠れているときはフェードしない")
    XCTAssertFalse(browser.sheetView.isHidden)
    stage.isHidden = false
  }
}
