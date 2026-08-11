import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 本物の `PaletteCard` を**実 `NSWindow` に載せ、実 `NSEvent` で叩く**テストの共通基底。
///
/// モデル単体テストでは掴めない欠陥——focus の所在、SwiftUI の更新パスで消えゆく子の評価——は
/// 実際に描いて実際にキーを届けないと再現しない。画面外座標・`canBecomeKey` の上書き・pump の刻みは
/// どれも微妙で、写すと片方だけ腐るため 1 か所に置く。
@MainActor
class PaletteCardWindowTestCase: OrbeTestCase {
  private var windows: [NSWindow] = []

  /// 窓は ordered-in の間 AppKit が保持するため、参照を捨てるだけでは解放されず居座る。
  /// `orderOut` で下ろしてから手放す（`close` は `isReleasedWhenClosed` と ARC が二重解放になる）。
  override func tearDown() {
    windows.forEach { $0.orderOut(nil) }
    windows.removeAll()
    super.tearDown()
  }

  /// borderless の窓は既定で `canBecomeKey` が false で、`NSApp.sendEvent` は key になれない窓へ
  /// keyDown を渡さない（窓の `sendEvent` すら呼ばれない）。配送を通すこの一点だけを開ける。
  /// 窓が実際に key になる必要はない——`.accessory` の非アクティブなテストでは
  /// `isKeyWindow` は最後まで false のまま、キーは first responder へ届く。
  private final class KeyDeliveryWindow: NSWindow {
    override var canBecomeKey: Bool { true }
  }

  func pump(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
  }

  /// keyDown を窓へ送る（keyCode は macOS の仮想キーコード）。
  func send(_ keyCode: UInt16, _ characters: String, to window: NSWindow) {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode)
    else { return XCTFail("キーイベントを作れない") }
    NSApp.sendEvent(event)
    pump(0.15)
  }

  /// 保留中の SwiftUI 更新を**実際のレイアウトまで**流し切る。モデルを書き換えただけでは子ビューは
  /// 作られも壊されもせず、`NSHostingView.layout()` がその更新パスを回して初めて起きる
  /// ——描画パスでしか出ない欠陥は、これを挟まないと修正前でも再現しない。
  func flush(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
    pump(0.3)
    window.contentView?.layoutSubtreeIfNeeded()
  }

  /// カードを載せた窓を**物理画面の外**に出す。`NSApp.sendEvent` は `windowNumber` で直接配送するため、
  /// 窓が見えていなくてもキーは届く——テストがユーザーの画面とフォーカスを触らずに済む。
  /// 枠のある窓は macOS が画面内へ押し戻す（`constrainFrameRect`）ので borderless で作る。
  func mount(_ model: PaletteModel) -> NSWindow {
    NSApplication.shared.setActivationPolicy(.accessory)
    let window = KeyDeliveryWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: PaletteCard(model: model).frame(width: 560))
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
    pump(0.4)
    return window
  }
}
