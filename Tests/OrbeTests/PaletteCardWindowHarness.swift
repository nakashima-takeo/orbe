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
/// 窓の作り方・キーとクリックの届け方・その後の更新の走らせ方はどれも微妙で、コピーすると片方だけ腐るため 1 か所に置く。
@MainActor
class PaletteCardWindowTestCase: OrbeTestCase {
  /// 載せたカードの入力欄に焦点が入るまで待つ。新しく載せたビューへの焦点は、`flush` の 1 回の更新の後にもう 1 段かかる。
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

  /// 窓座標（原点は左下）の 1 点を押して離し（→ `deliverClick`）、その後の SwiftUI の更新を走らせる（→ `flush`）。窓は
  /// `placeOffscreen` で並べておく。
  func click(
    _ point: NSPoint, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line
  ) {
    deliverClick(at: point, in: window, file: file, line: line)
    flush(window)
  }

  /// 中身を、並べない窓に載せて返す。主窓と同じ `OrbeWindow` に載せ、日本語入力の変換中に届いたキーをキーの処理に通さず
  /// 入力欄へ直に渡す `OrbeWindow.sendEvent` を、テストのキーにも通す。枠のある窓は macOS が画面内へ押し戻す
  /// （`constrainFrameRect`）ので borderless で作る（`placeOffscreen` で並べる窓もここで作る）。
  func host(_ content: NSView, size: NSSize) -> NSWindow {
    let window = OrbeWindow(
      contentRect: NSRect(origin: Self.offscreenOrigin, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = content
    holdUntilTestEnds(window)
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
