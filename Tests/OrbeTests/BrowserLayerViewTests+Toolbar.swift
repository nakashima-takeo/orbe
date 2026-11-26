import AppKit
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// ブラウザツールバーの単一ツリー配置（`BrowserToolbarLayout`）と URL 入力欄アイデンティティを守る。
/// 全面めくり・幅変更で URL 欄編集（文字列・IME・field editor 焦点）が破棄されないこと、
/// 最小右シート幅・極狭閉じプレビュー幅で 4 ボタンが左クリップされず、幅不足の全面めくりで
/// 案内ピルだけが 0×0 に畳まれることを検証する。
extension BrowserLayerViewTests {
  /// 右シート最小幅（240pt）でも 4 つの操作ボタンがツールバー領域内に収まり、全面 Peek の狭幅では
  /// 案内ピルが先に省略されてボタンが切れない。
  func testToolbarFitsAllActionButtonsAtMinimumSheetWidthAndDropsPeekPillWhenNarrow() throws {
    let leftSpan =
      Theme.Layout.browserBarLeading + Theme.Layout.browserIconButton * 3
      + Theme.Layout.browserBarGap * 3
    let rightSpan =
      Theme.Layout.browserBarTrailing + Theme.Layout.browserIconButton + Theme.Layout.browserBarGap

    // 1. 800pt 窓の最小右シート（240pt）で URL 欄が左右 4 ボタン領域を侵食せず収まる。
    let sheetHosted = hostBrowser()
    sheetHosted.browser.setMode(.sheet, animated: false)
    sheetHosted.browser.setSheetRatio(BrowserResizeSession.minRatio)
    let rect240 = try measureEditingURLField(in: sheetHosted, width: 800)
    XCTAssertEqual(
      sheetHosted.browser.sheetView.frame.width, BrowserResizeSession.closeThresholdWidth,
      accuracy: 0.5)
    XCTAssertGreaterThanOrEqual(rect240.minX, leftSpan, "240pt 右シートで左 3 ボタン側へはみ出さない")
    XCTAssertLessThanOrEqual(
      rect240.maxX, BrowserResizeSession.closeThresholdWidth - rightSpan,
      "240pt 右シートで右端の全面切替ボタンを押し出さない")

    // 短い URL での理想幅も 240pt を超えない。
    let compactModel = BrowserToolbarModel()
    compactModel.mode = .sheet
    compactModel.displayURL = BrowserDisplayURL(
      host: "a", path: "", isSecure: false, raw: "http://a")
    let compactIdeal = NSHostingView(
      rootView: BrowserBarRoot(
        model: compactModel, localization: sheetHosted.browser.localization,
        fontResolver: ChromeFontResolver())
    ).fittingSize.width
    XCTAssertLessThanOrEqual(
      compactIdeal, BrowserResizeSession.closeThresholdWidth,
      "通常ツールバーは 240pt 以下の幅に収められる")

    // 2. 全面 Peek: 広幅（600pt）では案内ピル分だけ右側余白が広がり、狭幅（320pt）ではピルを省略して収める。
    let wideHosted = hostBrowser()
    wideHosted.browser.setMode(.full, animated: false)
    wideHosted.browser.setPeekUnderlay(.editor)
    wideHosted.browser.setPeeking(true, animated: false)
    let wideRect = try measureEditingURLField(in: wideHosted, width: 600)

    let narrowHosted = hostBrowser()
    narrowHosted.browser.setMode(.full, animated: false)
    narrowHosted.browser.setPeekUnderlay(.editor)
    narrowHosted.browser.setPeeking(true, animated: false)
    let narrowRect = try measureEditingURLField(in: narrowHosted, width: 320)

    XCTAssertGreaterThan(
      (600 - wideRect.maxX) - (320 - narrowRect.maxX), 50,
      "広幅（600pt）では案内ピルが並び、狭幅（320pt）では案内ピルが省略されて右側専有幅が大きく縮む")
    XCTAssertGreaterThanOrEqual(narrowRect.minX, leftSpan, "320pt 全面 Peek で左 3 ボタン側へはみ出さない")
    XCTAssertLessThanOrEqual(
      narrowRect.maxX, 320 - rightSpan, "320pt 全面 Peek で右端の切替ボタンを押し出さない")
  }

  /// 全面表示で URL 欄を本物の `BrowserURLTextField`（field editor＋IME 未確定文字あり）で編集中に、
  /// `setPeeking(true)` → ピル表示閾値（`browserURLPeekMinWidth`）を跨ぐ幅変更 → `setPeeking(false)` を
  /// 往復しても、編集状態・入力文字列・IME 未確定文字・field editor 焦点・`NSTextField` 実体が破棄されない。
  func testFullPeekAndWidthThresholdCrossingPreserveURLEditingAndIME() throws {
    let hosted = hostBrowser()
    let (window, browser) = (hosted.window, hosted.browser)
    browser.setMode(.full, animated: false)
    browser.setPeekUnderlay(.editor)
    resizeHosted(hosted, width: 600)

    let editor = try beginAndFocusURLField(in: hosted)
    let originalField = try XCTUnwrap(firstTextField(in: browser.barHost))
    replaceAll("https://draft.example/", in: editor)
    markComposing(editor, "けんさく")
    let expectedText = editor.string

    func assertIntact(_ phase: String, file: StaticString = #filePath, line: UInt = #line) {
      flush(window)
      nextTurn(file: file, line: line)
      XCTAssertTrue(browser.isEditingURL, "\(phase): URL 編集状態が維持される", file: file, line: line)
      XCTAssertTrue(
        firstTextField(in: browser.barHost) === originalField,
        "\(phase): NSTextField の構造的アイデンティティが保たれる", file: file, line: line)
      XCTAssertTrue(
        window.firstResponder === editor, "\(phase): field editor の焦点が保たれる",
        file: file, line: line)
      XCTAssertTrue(editor.hasMarkedText(), "\(phase): IME 未確定文字列が維持される", file: file, line: line)
      XCTAssertEqual(editor.string, expectedText, "\(phase): 入力文字列が維持される", file: file, line: line)
    }

    browser.setPeeking(true, animated: false)
    assertIntact("全面 Peek 開始")

    resizeHosted(hosted, width: 280)
    assertIntact("Peek ピル省略幅（280pt）への縮小")

    resizeHosted(hosted, width: 600)
    assertIntact("Peek ピル再表示幅（600pt）への拡大")

    browser.setPeeking(false, animated: false)
    assertIntact("全面 Peek 解除")
  }

  /// 極狭幅（`120pt` 閉じプレビュー等 `146pt` 未満）で `BrowserToolbarLayout` と実 `BrowserBarRoot` を
  /// 配置しても左端「戻る」ボタンが `x >= bounds.minX` で左クリップされず、幅不足の全面めくりでは
  /// Peek ピルが 0×0 に畳まれ URL 欄・4 ボタンが壊れない。
  func testToolbarLayoutAlignsLeadingAtUltraNarrowWidthAndCollapsesPeekPillToZero() throws {
    let leading = Theme.Layout.browserBarLeading
    let trailing = Theme.Layout.browserBarTrailing
    let button = Theme.Layout.browserIconButton
    let gap = Theme.Layout.browserBarGap

    // 1. 極狭幅 120pt（閉じプレビュー最小幅）: 戻るボタンが左クリップされず左詰めに収まる。
    let frames120 = measureToolbarLayout(width: 120, showsPeekPill: false)
    XCTAssertEqual(frames120["back"]?.minX ?? -1, leading, accuracy: 0.5, "120pt で戻るボタンが左クリップされない")
    XCTAssertEqual(frames120["back"]?.width ?? 0, button, accuracy: 0.5)
    XCTAssertEqual(frames120["forward"]?.minX ?? -1, leading + button + gap, accuracy: 0.5)
    XCTAssertEqual(frames120["reload"]?.minX ?? -1, leading + (button + gap) * 2, accuracy: 0.5)
    XCTAssertEqual(frames120["url"]?.width ?? -1, 0, accuracy: 0.5, "極狭幅では URL 欄は幅 0 に畳まれる")

    // 2. 実 BrowserBarRoot の 120pt 配置でも URL 欄が左詰め位置を保つ。
    let ultraHosted = hostBrowser()
    ultraHosted.browser.setMode(.full, animated: false)
    let barRect120 = try measureEditingURLField(in: ultraHosted, width: 120)
    let leftThreeEnd = leading + button * 3 + gap * 3
    let urlPadDiff = Theme.Layout.browserURLPadLeading - Theme.Layout.browserURLPadTrailing
    XCTAssertGreaterThanOrEqual(
      barRect120.minX, leftThreeEnd - urlPadDiff, "実 BrowserBarRoot の 120pt で左詰めを保つ")

    // 3. 全面めくり: 広幅（600pt）ではピル表示＋URL >= 120pt、狭幅（280pt）ではピル 0×0＋4 ボタン健全。
    let wide = measureToolbarLayout(width: 600, showsPeekPill: true)
    XCTAssertEqual(wide["pill"]?.width ?? 0, 96, accuracy: 0.5, "広幅では Peek ピルが理想幅で並ぶ")
    XCTAssertGreaterThanOrEqual(wide["url"]?.width ?? 0, Theme.Layout.browserURLPeekMinWidth)
    XCTAssertLessThanOrEqual(wide["toggle"]?.maxX ?? 999, 600 - trailing + 0.5)

    let tight = measureToolbarLayout(width: 280, showsPeekPill: true)
    XCTAssertEqual(tight["back"]?.minX ?? -1, leading, accuracy: 0.5)
    XCTAssertEqual(tight["pill"]?.size, .zero, "幅不足の全面めくりでは Peek ピルを 0×0 に畳む")
    XCTAssertGreaterThan(tight["url"]?.width ?? 0, 100, "ピル省略後の残余幅を URL 欄へ配分する")
    XCTAssertEqual(tight["toggle"]?.width ?? 0, button, accuracy: 0.5)
    XCTAssertLessThanOrEqual(tight["toggle"]?.maxX ?? 999, 280 - trailing + 0.5)
  }

  private func resizeHosted(_ hosted: Hosted, width: CGFloat) {
    let size = NSSize(width: width, height: 600)
    hosted.window.setFrame(NSRect(origin: .zero, size: size), display: false)
    hosted.stage.frame = NSRect(origin: .zero, size: size)
    hosted.stage.layoutSubtreeIfNeeded()
  }

  private func measureEditingURLField(in hosted: Hosted, width: CGFloat) throws -> NSRect {
    resizeHosted(hosted, width: width)
    hosted.browser.beginURLEditing()
    hosted.stage.layoutSubtreeIfNeeded()
    flush(hosted.window)
    let field = try XCTUnwrap(firstTextField(in: hosted.browser.barHost))
    return field.convert(field.bounds, to: hosted.browser.barHost)
  }

  private func firstTextField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField { return field }
    for subview in view.subviews {
      if let found = firstTextField(in: subview) { return found }
    }
    return nil
  }

  private func measureToolbarLayout(width: CGFloat, showsPeekPill: Bool) -> [String: CGRect] {
    let store = ToolbarProbeStore()
    let height = Theme.Layout.browserBar - Theme.Stroke.hairline
    let btn = Theme.Layout.browserIconButton
    let root = BrowserToolbarLayout(
      spacing: Theme.Layout.browserBarGap,
      urlMarginX: Theme.Layout.browserURLMarginX,
      urlPeekMinWidth: Theme.Layout.browserURLPeekMinWidth
    ) {
      ToolbarLayoutProbe(id: "back", store: store).frame(width: btn, height: btn)
      ToolbarLayoutProbe(id: "forward", store: store).frame(width: btn, height: btn)
      ToolbarLayoutProbe(id: "reload", store: store).frame(width: btn, height: btn)
      ToolbarLayoutProbe(id: "url", store: store)
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: Theme.Layout.browserURLHeight)
        .layoutValue(key: BrowserToolbarRoleKey.self, value: .url)
      if showsPeekPill {
        Color.clear
          .frame(width: 96, height: 20)
          .frame(
            minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
            alignment: .leading
          )
          .clipped()
          .overlay { ToolbarLayoutProbe(id: "pill", store: store) }
          .layoutValue(key: BrowserToolbarRoleKey.self, value: .peekPill)
      }
      ToolbarLayoutProbe(id: "toggle", store: store).frame(width: btn, height: btn)
    }
    .padding(.leading, Theme.Layout.browserBarLeading)
    .padding(.trailing, Theme.Layout.browserBarTrailing)
    .frame(width: width, height: height, alignment: .leading)

    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    return store.rects(in: host)
  }
}

@MainActor
private final class ToolbarProbeStore {
  var views: [String: NSView] = [:]

  func rects(in host: NSView) -> [String: CGRect] {
    var result: [String: CGRect] = [:]
    for (id, view) in views {
      result[id] = view.convert(view.bounds, to: host)
    }
    return result
  }
}

private struct ToolbarLayoutProbe: NSViewRepresentable {
  let id: String
  let store: ToolbarProbeStore

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    store.views[id] = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    store.views[id] = nsView
  }
}
