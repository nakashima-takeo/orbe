import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// タブ行のタブを中クリックでタブごと閉じる経路の検証。
///
/// ドメイン側（`StatusRowModel.onCloseTab` → `WindowController.closeTab`）に加え、
/// **AppKit のイベント配送経路**——`MiddleClickCatcher.CatcherView` の hitTest ゲートと
/// buttonNumber 絞り込み——を合成イベントで通す。SwiftUI のジェスチャは中ボタンを拾えず
/// この catcher だけが受け口なので、ここが崩れると機能ごと消えるか、逆に catcher がタブ全面を
/// 覆って選択・並び替え・改名を殺す。
final class ChromeMiddleClickTests: XCTestCase {

  private var tempStore: URL!
  private var windows: [NSWindow] = []

  override func setUp() {
    super.setUp()
    tempStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-test-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tempStore
    SettingsPersistence.fileURLOverride = tempStore.appendingPathExtension("settings")
    AppStatePersistence.fileURLOverride = tempStore.appendingPathExtension("appstate")
    // 言語確定済み（returning user）として起動し、初回言語選択 overlay を出さない。
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  /// 窓は ordered-in の間 AppKit が保持するため、参照を捨てるだけでは解放されず居座る。
  /// `orderOut` で下ろしてから手放す（`close` は `isReleasedWhenClosed` と ARC が二重解放になる）。
  override func tearDown() {
    windows.forEach { $0.orderOut(nil) }
    windows.removeAll()
    WorkspacePersistence.fileURLOverride = nil
    SettingsPersistence.fileURLOverride = nil
    AppStatePersistence.fileURLOverride = nil
    try? FileManager.default.removeItem(at: tempStore)
    super.tearDown()
  }

  // MARK: - ドメイン: onCloseTab → closeTab

  /// 非選択タブの中クリック（`onCloseTab`）は、選択切替を挟まずそのタブだけをタブごと閉じる。
  func testMiddleClickClosesTabWithoutSwitchingSelection() {
    let wc = WindowController()
    wc.newTab()
    wc.newTab()
    XCTAssertEqual(wc.current.tabs.count, 3, "前提: タブ 3 枚で末尾がアクティブ")
    let active = wc.current.tabs[wc.current.active]
    let survivor = wc.current.tabs[1]

    wc.statusModel.onCloseTab(0)  // 非選択の先頭タブを中クリック

    XCTAssertEqual(wc.current.tabs.count, 2, "中クリックしたタブだけが閉じる")
    XCTAssertTrue(wc.current.tabs[wc.current.active] === active, "アクティブタブは切り替わらない")
    XCTAssertTrue(wc.current.tabs.first === survivor, "閉じたタブ以外は残る")
  }

  /// 範囲外 index で呼んでも落ちず、タブ集合も変えない（`onSelect` と同じ防御水準）。
  func testMiddleClickIgnoresOutOfRangeIndex() {
    let wc = WindowController()
    wc.newTab()
    let before = wc.current.tabs.count

    wc.statusModel.onCloseTab(before)
    wc.statusModel.onCloseTab(-1)

    XCTAssertEqual(wc.current.tabs.count, before, "範囲外はタブ集合を変えない")
  }

  // MARK: - AppKit イベント配送経路

  /// 中ボタンの `otherMouseDown` を窓へ配送すると、その座標のタブが閉じる。
  /// catcher の矩形・hitTest ゲート・buttonNumber 絞り込み・`closeTab` までの配線を一度に通す。
  func testMiddleButtonEventOnTabClosesThatTab() throws {
    let wc = WindowController()
    wc.newTab()
    wc.newTab()
    let window = try mount(wc)
    let catchers = try tabCatchers(in: window)
    XCTAssertEqual(catchers.count, 3, "catcher はタブ 1 枚に 1 つ載る")
    let survivors = [wc.current.tabs[1], wc.current.tabs[2]]

    window.sendEvent(try otherDown(button: 2, at: center(of: catchers[0])))  // 先頭タブを中クリック

    XCTAssertEqual(wc.current.tabs.count, 2, "配送された中クリックがタブを閉じる")
    XCTAssertTrue(
      zip(wc.current.tabs, survivors).allSatisfy { $0 === $1 }, "閉じたのはクリック座標のタブ（先頭）だけ")
  }

  /// サイドボタン（buttonNumber 3）では閉じない。hitTest が catcher を返さず、
  /// 仮に catcher へ直接届いても `otherMouseDown` が弾く——二重ガードの両方を確かめる。
  func testSideButtonEventDoesNotCloseTab() throws {
    let wc = WindowController()
    wc.newTab()
    let window = try mount(wc)
    let catcher = try XCTUnwrap(tabCatchers(in: window).first, "先頭タブの catcher")
    let point = center(of: catcher)
    let side = try otherDown(button: 3, at: point)

    XCTAssertFalse(
      try hitTest(point, in: window) is MiddleClickCatcher.CatcherView,
      "サイドボタン配送中は catcher が hitTest に出ない")
    window.sendEvent(side)
    XCTAssertEqual(wc.current.tabs.count, 2, "配送してもタブは閉じない")

    catcher.otherMouseDown(with: side)  // hitTest を迂回して直接届いた場合
    XCTAssertEqual(wc.current.tabs.count, 2, "catcher 自身も中ボタン以外を弾く")
  }

  /// 左ボタン系の配送中は catcher が hitTest で素通しし、タブ行の SwiftUI 側が受ける。
  /// ＝ 選択（tap）・並び替え（drag）・改名の既存操作を一切奪わない。
  func testLeftButtonEventsPassThroughCatcher() throws {
    let wc = WindowController()
    wc.newTab()
    let window = try mount(wc)
    let catcher = try XCTUnwrap(tabCatchers(in: window).first, "先頭タブの catcher")
    let point = center(of: catcher)
    let host = try XCTUnwrap(window.contentView, "chrome ルート")

    for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged] {
      _ = try leftEvent(type, at: point)
      let hit = try XCTUnwrap(try hitTest(point, in: window), "タブ中心は誰かが受ける")
      XCTAssertFalse(hit is MiddleClickCatcher.CatcherView, "\(type) の配送中は catcher が素通しする")
      XCTAssertTrue(hit.isDescendant(of: host), "受けたのは chrome の SwiftUI 側")
    }
  }

  // MARK: - 窓の組み立て

  /// chrome を載せた窓を**物理画面の外**に組む。`sendEvent` は ordered-in の窓でしか配送せず、
  /// `WindowController` の窓は titled なので macOS が画面内へ押し戻す（`constrainFrameRect`）——
  /// 押し戻されない borderless の窓へ chrome を移し、ユーザーの画面を触らずに配送を通す。
  private func mount(_ wc: WindowController) throws -> NSWindow {
    wc.flushChrome()  // chrome は coalesce 済み——mount 前に最終状態（タブ枚数）を確定させる
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = try XCTUnwrap(wc.window.contentView, "SwiftUI ルートの contentView")
    window.orderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    windows.append(window)
    return window
  }

  /// タブ行の catcher を左から順に返す（index がタブ index に一致する）。
  private func tabCatchers(in window: NSWindow) throws -> [MiddleClickCatcher.CatcherView] {
    let host = try XCTUnwrap(window.contentView, "chrome ルート")
    var found: [MiddleClickCatcher.CatcherView] = []
    func walk(_ view: NSView) {
      if let catcher = view as? MiddleClickCatcher.CatcherView { found.append(catcher) }
      view.subviews.forEach(walk)
    }
    walk(host)
    return found.sorted { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x }
  }

  private func center(of view: NSView) -> NSPoint {
    view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
  }

  private func hitTest(_ point: NSPoint, in window: NSWindow) throws -> NSView? {
    try XCTUnwrap(window.contentView, "chrome ルート").hitTest(point)
  }

  // MARK: - イベント合成

  /// 窓座標 `point` を指す `otherMouseDown` を作り、配送できる状態にする。
  ///
  /// CGEvent 経由なのは `NSEvent.mouseEvent` が buttonNumber を常に 0 にしてしまい、中ボタンと
  /// サイドボタンを区別できないため。CGEvent は上原点の画面座標を取り、窓を持たない NSEvent の
  /// `locationInWindow` は下原点の画面座標になる——その反転量を実測し、欲しい窓座標がそのまま
  /// `locationInWindow` に出る CG 座標を逆算する（宛先の窓は `sendEvent` で直接指す）。
  private func otherDown(button: Int, at point: NSPoint) throws -> NSEvent {
    let flip = try screenFlipOrigin()
    let cg = try XCTUnwrap(
      CGEvent(
        mouseEventSource: nil, mouseType: .otherMouseDown,
        mouseCursorPosition: CGPoint(x: point.x, y: flip - point.y), mouseButton: .center),
      "otherMouseDown の CGEvent")
    cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
    return try makeCurrent(try XCTUnwrap(NSEvent(cgEvent: cg), "NSEvent へ変換"))
  }

  /// CG の上原点座標を Cocoa の下原点座標へ移す反転量（＝主ディスプレイ高）を、探り 1 つで実測する。
  private func screenFlipOrigin() throws -> CGFloat {
    let probe = try XCTUnwrap(
      CGEvent(
        mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero,
        mouseButton: .left), "座標校正の CGEvent")
    return try XCTUnwrap(NSEvent(cgEvent: probe), "座標校正の NSEvent").locationInWindow.y
  }

  /// 左ボタン系イベント（buttonNumber は AppKit が型から決めるので合成でそのまま使える）。
  /// 宛先は持たせない——検証で使うのは「配送中のイベント」としての `NSApp.currentEvent` だけで、
  /// hitTest の宛先は座標で明示する。
  private func leftEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
    try makeCurrent(
      try XCTUnwrap(
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
          eventNumber: 0, clickCount: 1, pressure: 1), "\(type) のイベント"))
  }

  /// アプリのイベントキューを 1 往復させて `NSApp.currentEvent` を立てる。
  /// `CatcherView.hitTest` はそれを読んで中ボタンか判定するため、キューを通さないと nil のまま
  /// ——どのイベントでも catcher が素通しし、ゲートの検証にならない。
  private func makeCurrent(_ event: NSEvent) throws -> NSEvent {
    NSApp.postEvent(event, atStart: true)
    return try XCTUnwrap(
      NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true),
      "投入したイベントの取り出し")
  }
}
