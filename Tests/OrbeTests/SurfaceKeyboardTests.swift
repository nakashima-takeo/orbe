import XCTest

@testable import Orbe

/// `textCarriesToKey`: C0 制御文字と DEL を `key.text` に載せないガード（libghostty surface / NSEvent 実キー非依存）。
/// Shift+Enter・Shift+Backspace の修飾と、翻訳が alt を落とさない構成での Alt+Enter / Option+Backspace の修飾が、
/// 素のキーに潰れないための要。
final class SurfaceKeyboardTests: OrbeTestCase {
  /// 0x20 以上で DEL でない先頭バイトだけ載せる。space（0x20）と `~`（0x7E）は載せる側の境界、0x1F と DEL（0x7F）は
  /// 載せない側の境界。マルチバイト UTF-8 は先頭バイトが 0x80 以上なので常に載る（scalar でなくバイト判定）。
  func testOnlyNonControlTextCarriesToTheKey() {
    XCTAssertTrue(SurfaceKeyInput.textCarriesToKey(" "))
    XCTAssertFalse(SurfaceKeyInput.textCarriesToKey("\u{1f}"))
    XCTAssertTrue(SurfaceKeyInput.textCarriesToKey("~"))
    XCTAssertFalse(SurfaceKeyInput.textCarriesToKey("\u{7f}"))
    XCTAssertFalse(SurfaceKeyInput.textCarriesToKey("\r"), "Enter")
    XCTAssertTrue(SurfaceKeyInput.textCarriesToKey("あ"))
    XCTAssertTrue(SurfaceKeyInput.textCarriesToKey("🎉"))
  }
}
