import AppKit
import GhosttyKit
import XCTest

@testable import Orbe

/// キーボード入力の純ロジックを固定する（libghostty surface / NSEvent 実キー非依存）。
/// - `eventModifierFlags`: option-as-alt 翻訳で使う ghostty mods → NSEvent フラグの逆変換表。
///   ここがずれると Option+Enter 等の翻訳が静かに壊れる（人のレビューなしで漏れる契約）。
/// - `textCarriesToKey`: 制御文字を `key.text` に載せない 0x20 ガード。Alt+Enter が素の Enter に
///   潰れないための要。
final class SurfaceKeyboardTests: XCTestCase {

  // MARK: - eventModifierFlags（ghostty mods → NSEvent フラグ逆変換）

  private func mods(_ raw: UInt32) -> ghostty_input_mods_e { ghostty_input_mods_e(rawValue: raw) }

  /// 各修飾ビットが対応する NSEvent フラグへ 1:1 で戻る（alt→option の対応を含む全ビット）。
  func testEachModBitMapsToItsFlag() {
    XCTAssertEqual(SurfaceView.eventModifierFlags(mods(GHOSTTY_MODS_SHIFT.rawValue)), .shift)
    XCTAssertEqual(SurfaceView.eventModifierFlags(mods(GHOSTTY_MODS_CTRL.rawValue)), .control)
    XCTAssertEqual(SurfaceView.eventModifierFlags(mods(GHOSTTY_MODS_ALT.rawValue)), .option)
    XCTAssertEqual(SurfaceView.eventModifierFlags(mods(GHOSTTY_MODS_SUPER.rawValue)), .command)
  }

  /// 複数ビットは各フラグの和へ戻る。
  func testCombinedModsMapToUnion() {
    let raw = GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_ALT.rawValue | GHOSTTY_MODS_SUPER.rawValue
    XCTAssertEqual(SurfaceView.eventModifierFlags(mods(raw)), [.shift, .option, .command])
  }

  /// 空 mods は空フラグ。
  func testEmptyModsMapToEmptyFlags() {
    XCTAssertEqual(SurfaceView.eventModifierFlags(mods(0)), [])
  }

  /// CAPS は逆変換しない——translationEvent は 4 フラグ（shift/ctrl/option/command）だけを exact に
  /// 転写する契約。`ghosttyMods` は capsLock→CAPS を張るが逆写像はそれを含めない（非対称を固定）。
  func testCapsLockIsNotReversed() {
    XCTAssertEqual(SurfaceView.eventModifierFlags(mods(GHOSTTY_MODS_CAPS.rawValue)), [])
    // CAPS を混ぜても他ビットのみ戻り、.capsLock は付かない。
    let raw = GHOSTTY_MODS_CAPS.rawValue | GHOSTTY_MODS_CTRL.rawValue
    XCTAssertEqual(SurfaceView.eventModifierFlags(mods(raw)), .control)
  }

  // MARK: - textCarriesToKey（0x20 制御文字ガード）

  /// 印字可能文字は key.text に載せる。
  func testPrintableTextCarries() {
    XCTAssertTrue(SurfaceView.textCarriesToKey("a"))
    XCTAssertTrue(SurfaceView.textCarriesToKey("Z"))
    XCTAssertTrue(SurfaceView.textCarriesToKey("1"))
  }

  /// space(0x20) は載せる下端の境界、0x1F は載せない上端の境界。
  func testControlBoundaryAt0x20() {
    XCTAssertTrue(SurfaceView.textCarriesToKey(" "))  // 0x20
    XCTAssertFalse(SurfaceView.textCarriesToKey("\u{1f}"))  // 0x1F
  }

  /// 制御文字は載せない（Enter=\r・ESC・NUL）。Alt+Enter が素の Enter に潰れないための要。
  func testControlCharsDoNotCarry() {
    XCTAssertFalse(SurfaceView.textCarriesToKey("\r"))  // 0x0D Enter
    XCTAssertFalse(SurfaceView.textCarriesToKey("\u{1b}"))  // ESC
    XCTAssertFalse(SurfaceView.textCarriesToKey("\u{00}"))  // NUL
  }

  /// 空文字列は載せない（先頭バイト無し）。
  func testEmptyStringDoesNotCarry() {
    XCTAssertFalse(SurfaceView.textCarriesToKey(""))
  }

  /// マルチバイト UTF-8 は先頭バイトが 0x80 以上のため常に載せる（scalar でなくバイト判定）。
  func testMultibyteUTF8Carries() {
    XCTAssertTrue(SurfaceView.textCarriesToKey("あ"))
    XCTAssertTrue(SurfaceView.textCarriesToKey("🎉"))
  }
}
