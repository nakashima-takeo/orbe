import AppKit
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// ポップオーバー単一 `ScrollView` の高さ境界跨ぎでの入力/IME 維持、狭幅・低高・極低高クランプ、
/// 自然高さ非膨張、および `BrowserPopoverHost` の `hitTest` 素通し・外側クリック閉鎖・右クリック遮断を守る。
extension BrowserLayerViewTests {
  /// ポップオーバー表示中に高さ境界（スクロール不要 ⇄ スクロール必須）を往復しても、
  /// 単一 `ScrollView` によりフォーム `BrowserInlineTextField` の構造的アイデンティティ・
  /// 焦点・入力文字列・IME 未確定文字・開状態が破棄されない。
  func testPopoverHeightThresholdCrossingPreservesFormFieldIdentityAndIME() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    window.onFirstResponderChange = { _ in
      browser.setFocused(window.isKeyWindow && browser.focusIsInside)
    }

    browser.setMode(.full, animated: false)
    browser.focusBrowser()
    browser.openPopover(.createSpace)
    flush(window)
    pumpMain(
      until: {
        (window.firstResponder as? NSTextView)?.isDescendant(of: browser.popoverHost) == true
      }, "自由スペース作成フォーム入力欄に焦点")

    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    let originalField = try XCTUnwrap(findPopoverTextField(in: browser.popoverHost))
    replaceAll("調査ノート", in: editor)
    markComposing(editor, "へんかん")
    let expected = editor.string

    func resizeWindow(
      height: CGFloat, phase: String, file: StaticString = #filePath, line: UInt = #line
    ) {
      let size = NSSize(width: 1000, height: height)
      window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
      hosted.stage.frame = NSRect(origin: .zero, size: size)
      hosted.stage.layoutSubtreeIfNeeded()
      flush(window)
      nextTurn(file: file, line: line)
      XCTAssertTrue(browser.isPopoverOpen, "\(phase): ポップオーバー開状態を維持", file: file, line: line)
      XCTAssertTrue(
        findPopoverTextField(in: browser.popoverHost) === originalField,
        "\(phase): NSTextField の構造的アイデンティティを破棄しない", file: file, line: line)
      XCTAssertTrue(
        window.firstResponder === editor, "\(phase): field editor 焦点を維持", file: file, line: line)
      XCTAssertTrue(editor.hasMarkedText(), "\(phase): IME 未確定文字を維持", file: file, line: line)
      XCTAssertEqual(editor.string, expected, "\(phase): 入力文字列を維持", file: file, line: line)
    }

    // 自然高さフィット（600pt）→ スクロール必須（200pt）→ 再び自然高さ（600pt）を往復。
    resizeWindow(height: 200, phase: "低高（200pt・スクロール発動）")
    let tightScroll = try XCTUnwrap(firstScrollView(in: browser.popoverHost))
    let tightDoc = try XCTUnwrap(tightScroll.documentView)
    XCTAssertGreaterThan(
      tightDoc.frame.height, tightScroll.contentView.bounds.height,
      "200pt では単一 ScrollView 内でスクロール状態へ移行する")

    resizeWindow(height: 600, phase: "広高（600pt・自然高さ復帰）")
    editor.unmarkText()
  }

  /// ポップオーバーは狭幅・低高・極低高で `belowBar` 内側へクランプしつつ、通常高さでは
  /// 貪欲膨張せず自然高さに収まる。閉時は `hitTest` を素通しし、開時は外側クリック閉鎖・
  /// 右クリック/中クリック遮断を守る。
  func testPopoverHostHitTestBlockingAndLayoutClampingWithoutGreedyExpansion() throws {
    let hosted = hostBrowser()
    let (window, stage, browser) = (hosted.window, hosted.stage, hosted.browser)
    browser.setMode(.full, animated: false)
    browser.focusBrowser()
    placeOffscreen(window)

    // 1. 閉時は popoverHost が非表示で hitTest を素通しする。
    let centerPoint = browser.belowBar.convert(NSPoint(x: 500, y: 200), to: stage)
    let closedHit = try XCTUnwrap(stage.hitTest(centerPoint))
    XCTAssertFalse(
      closedHit === browser.popoverHost || closedHit.isDescendant(of: browser.popoverHost),
      "閉時は popoverHost が hitTest に参加しない")

    // 2. 開時（通常 1000×600）: 自然高さフィット（貪欲膨張しない）＋右クリック/中クリック遮断。
    browser.openPopover(.profile)
    flush(window)
    let normalScroll = try XCTUnwrap(firstScrollView(in: browser.popoverHost))
    XCTAssertLessThan(
      normalScroll.frame.height, browser.belowBar.bounds.height - 100,
      "通常高さでは belowBar いっぱいへ貪欲膨張せず自然高さに収まる")
    XCTAssertEqual(
      normalScroll.frame.width, Theme.Layout.browserPopoverProfileWidth, accuracy: 2.0)

    let rightClick = NSEvent.mouse(.rightMouseDown, at: NSPoint(x: 700, y: 200), in: window)
    let otherClick = NSEvent.mouse(.otherMouseDown, at: NSPoint(x: 700, y: 200), in: window)
    browser.popoverHost.rightMouseDown(with: rightClick)
    browser.popoverHost.otherMouseDown(with: otherClick)
    XCTAssertTrue(browser.isPopoverOpen, "右クリック・中クリックでポップオーバーが誤閉鎖しない")

    // 3. 狭幅（240pt）・低高（180pt）・極低高（80pt）クランプ。
    let sizes = [
      NSSize(width: 240, height: 600),
      NSSize(width: 1000, height: 180),
      NSSize(width: 240, height: 80),
    ]
    for size in sizes {
      window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
      stage.frame = NSRect(origin: .zero, size: size)
      stage.layoutSubtreeIfNeeded()
      flush(window)
      let sv = try XCTUnwrap(firstScrollView(in: browser.popoverHost))
      let maxW = max(0, browser.belowBar.bounds.width - Theme.Layout.browserPopoverInset * 2)
      let maxH = max(
        0,
        browser.belowBar.bounds.height - Theme.Layout.browserPopoverHeaderY
          - Theme.Layout.browserPopoverInset)
      XCTAssertLessThanOrEqual(sv.frame.width, maxW + 1, "幅が belowBar 内側へクランプされる (\(size))")
      XCTAssertLessThanOrEqual(sv.frame.height, maxH + 1, "高さが belowBar 内側へクランプされる (\(size))")
    }

    // 4. 外側クリックで閉鎖＋focusBrowser()。
    window.setFrame(NSRect(origin: window.frame.origin, size: stageSize), display: false)
    stage.frame = NSRect(origin: .zero, size: stageSize)
    stage.layoutSubtreeIfNeeded()
    flush(window)
    clickWindowPoint(NSPoint(x: 850, y: 200), in: window)
    XCTAssertFalse(browser.isPopoverOpen, "外側クリックでポップオーバーが閉じる")
    XCTAssertTrue(window.firstResponder === browser)
  }

  func firstScrollView(in view: NSView) -> NSScrollView? {
    if let sv = view as? NSScrollView { return sv }
    for sub in view.subviews {
      if let found = firstScrollView(in: sub) { return found }
    }
    return nil
  }

  func findPopoverTextField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField { return field }
    for sub in view.subviews {
      if let found = findPopoverTextField(in: sub) { return found }
    }
    return nil
  }
}
