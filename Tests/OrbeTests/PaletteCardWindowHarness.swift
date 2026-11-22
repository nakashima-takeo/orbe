import AppKit
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 本物の `PaletteCard` を**実 `NSWindow` に載せ、実 `NSEvent` で叩く**テストの共通基底。
///
/// モデル単体テストでは掴めない欠陥——focus の所在、SwiftUI の更新パスで消えゆく子の評価——は
/// 実際に描いて実際にキーを届けないと再現しない。窓は並べず（OS の表示の並びに入れず。並べるのは
/// `placeOffscreen` だけ）、キーは窓を名指しして届ける。SwiftUI の focus と更新は並べない窓でも回る。
/// 窓の作り方・pump の刻み・キーとクリックの届け方はどれも微妙で、コピーすると片方だけ腐るため 1 か所に置く。
@MainActor
class PaletteCardWindowTestCase: OrbeTestCase {
  /// 返した窓を捨てるテストがあるので、載せた中身がテストの間に解放されないよう、テストの終わりまで保持する。
  private var windows: [NSWindow] = []

  override func tearDown() {
    windows.removeAll()
    super.tearDown()
  }

  func awaitFieldFocus(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
    pumpMain(until: { window.firstResponder is NSTextView }, "入力欄に焦点が入る", file: file, line: line)
  }

  /// keyDown を窓へ届ける（keyCode は macOS の仮想キーコード）。
  func send(
    _ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [],
    repeating: Bool = false, to window: NSWindow
  ) {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: repeating, keyCode: keyCode)
    else { return XCTFail("キーイベントを作れない") }
    deliverKeyDown(event, to: window)
    flush(window)
  }

  /// 窓座標（原点は左下）の 1 点を実 NSEvent のマウスでクリックする。マウスは並んだ窓にしか届かないので、窓は
  /// `placeOffscreen` で並べておく。離す方のイベントは先にキューへ入れておく——入力欄のテキストビューが押下を受けると、
  /// 離すイベントがキューに来るまで待つマウスの追跡ループに入り、離すイベントを後から送ると、押下を送った `sendEvent` が
  /// 戻ってこない。
  func click(_ point: NSPoint, in window: NSWindow) {
    guard window.isVisible else {
      return XCTFail("マウスは並んだ窓にしか届かない。先に placeOffscreen で並べる")
    }
    let make = { (type: NSEvent.EventType) in
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }
    NSApp.postEvent(make(.leftMouseUp), atStart: false)
    NSApp.sendEvent(make(.leftMouseDown))
    if let pending = NSApp.nextEvent(
      matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    {
      NSApp.sendEvent(pending)
    }
    flush(window)
  }

  /// 保留中の SwiftUI 更新を 1 パス流し切る。モデルを書き換えただけでは子ビューは作られも壊されもせず、
  /// RunLoop（SwiftUI が仕込む observer）か強制レイアウトのどちらかが更新パスを回して初めて起きる。
  /// キーを送らずに状態だけ変える段（サブパレットへ潜る等）では回す機会が他に無いため、ここを挟まないと
  /// 描画パスでしか出ない欠陥は修正前でも再現しない。

  /// 中身を、並べない窓に載せて返す。主窓と同じ `OrbeWindow` に載せ、日本語入力の変換中に届いたキーをキーの処理に通さず
  /// 入力欄へ直に渡す `OrbeWindow.sendEvent` を、テストのキーにも通す。枠のある窓は macOS が画面内へ押し戻す
  /// （`constrainFrameRect`）ので borderless で作る（`placeOffscreen` で並べる窓もここで作る）。
  func host(_ content: NSView, size: NSSize) -> NSWindow {
    let window = OrbeWindow(
      contentRect: NSRect(origin: Self.offscreenOrigin, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = content
    windows.append(window)
    flush(window)
    return window
  }

  /// カードには窓高をそのまま上限として渡す＝窓いっぱいまで使える状態（ここに来るのはキー配送を
  /// 見るテストだけで、高さの取り合いには関心がない。収まりは `PaletteFitTests` が別に見る）。
  func mount(_ model: PaletteModel) -> NSWindow {
    let windowHeight: CGFloat = 500
    return host(
      NSHostingView(rootView: PaletteCard(model: model, maxHeight: windowHeight).frame(width: 560)),
      size: NSSize(width: 600, height: windowHeight))
  }
}
