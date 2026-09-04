import GhosttyKit
import XCTest

@testable import Orbe

/// `ControlKey.parse` の全分岐を固定する。send_key が修飾を黙殺して素の文字を注入しない契約
/// （cmd/super 付き単一文字・未知修飾・複数 scalar・制御文字は拒否）と、物理キー経路と同じ形の
/// `SurfaceKeyInput` に解決する契約を守る。libghostty 非依存（keycode/mods 定数の値だけを参照）。
final class ControlKeyParseTests: OrbeTestCase {
  private func mods(_ raw: UInt32) -> ghostty_input_mods_e { ghostty_input_mods_e(rawValue: raw) }

  /// keycode 無しの単一文字入力。
  private func char(
    _ text: String, unshifted: UInt32, mods: UInt32 = 0, consumed: UInt32 = 0
  ) -> SurfaceKeyInput {
    SurfaceKeyInput(
      keycode: SurfaceKeyInput.noKeycode, text: text, unshiftedCodepoint: unshifted,
      mods: self.mods(mods), consumedMods: self.mods(consumed))
  }

  func testNamedKeysCarryRealKeycode() {
    XCTAssertEqual(
      ControlKey.parse("enter"),
      SurfaceKeyInput(
        keycode: 36, text: nil, unshiftedCodepoint: 0, mods: mods(0), consumedMods: mods(0)))
    XCTAssertEqual(ControlKey.parse("up")?.keycode, 126)
    XCTAssertEqual(ControlKey.parse("Escape")?.keycode, 53)
  }

  /// space は keycode だけでは何も書かれない（関数キー表に無い）ので text と unshifted を持つ。
  func testSpaceCarriesText() {
    XCTAssertEqual(
      ControlKey.parse("space"),
      SurfaceKeyInput(
        keycode: 49, text: " ", unshiftedCodepoint: 0x20, mods: mods(0), consumedMods: mods(0)))
  }

  func testModifierCompositionOnNamedKey() {
    let parsed = ControlKey.parse("cmd+shift+up")
    XCTAssertEqual(parsed?.keycode, 126)
    XCTAssertEqual(parsed?.mods.rawValue, GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
    XCTAssertEqual(parsed?.consumedMods.rawValue, 0)
  }

  func testPlainSingleChar() {
    XCTAssertEqual(ControlKey.parse("a"), char("a", unshifted: 0x61))
    // 大文字指定は lowercased（大文字は shift+a で明示する）。
    XCTAssertEqual(ControlKey.parse("A"), char("a", unshifted: 0x61))
  }

  /// ctrl / alt は消費せず修飾として渡す（符号化は libghostty）。C0 レンジ外も受ける。
  func testCtrlAndAltStayAsMods() {
    XCTAssertEqual(
      ControlKey.parse("ctrl+c"), char("c", unshifted: 0x63, mods: GHOSTTY_MODS_CTRL.rawValue))
    XCTAssertEqual(
      ControlKey.parse("ctrl+1"), char("1", unshifted: 0x31, mods: GHOSTTY_MODS_CTRL.rawValue))
    for spec in ["alt+b", "option+b", "opt+b", "meta+b"] {
      XCTAssertEqual(
        ControlKey.parse(spec), char("b", unshifted: 0x62, mods: GHOSTTY_MODS_ALT.rawValue), spec)
    }
    XCTAssertEqual(
      ControlKey.parse("ctrl+alt+x"),
      char("x", unshifted: 0x78, mods: GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_ALT.rawValue))
  }

  /// shift は大文字化が起きたときだけ消費する。
  func testShiftUppercasesAndIsConsumed() {
    XCTAssertEqual(
      ControlKey.parse("shift+a"),
      char(
        "A", unshifted: 0x61, mods: GHOSTTY_MODS_SHIFT.rawValue,
        consumed: GHOSTTY_MODS_SHIFT.rawValue))
    XCTAssertEqual(
      ControlKey.parse("ctrl+shift+a"),
      char(
        "A", unshifted: 0x61, mods: GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SHIFT.rawValue,
        consumed: GHOSTTY_MODS_SHIFT.rawValue))
  }

  /// 大文字化しない文字はレイアウト不明で `!` 等を作れないので、shift を修飾のまま残す。
  func testShiftOnNonLetterStaysAsMod() {
    XCTAssertEqual(
      ControlKey.parse("shift+1"), char("1", unshifted: 0x31, mods: GHOSTTY_MODS_SHIFT.rawValue))
  }

  func testSuperOnSingleCharRejected() {
    XCTAssertNil(ControlKey.parse("cmd+c"))
    XCTAssertNil(ControlKey.parse("super+a"))
  }

  func testUnknownModifierRejected() {
    XCTAssertNil(ControlKey.parse("hyper+a"))
  }

  func testEmptyAndMultiChar() {
    XCTAssertNil(ControlKey.parse(""))
    XCTAssertNil(ControlKey.parse("ctrl+"))
    // 名前付きキーでない複数文字は拒否。
    XCTAssertNil(ControlKey.parse("abc"))
  }

  /// 複数 scalar の grapheme と制御文字は単一文字として受けない（send_text の領分）。
  func testMultiScalarGraphemeAndControlCharRejected() {
    XCTAssertNil(ControlKey.parse("👨‍👩‍👧"))
    XCTAssertNil(ControlKey.parse("\u{03}"))
    XCTAssertNil(ControlKey.parse("\u{7f}"))
  }

  /// 非 ASCII の単一 scalar は受ける（kitty は unshifted から符号化する）。
  func testNonAsciiSingleScalar() {
    XCTAssertEqual(ControlKey.parse("あ"), char("あ", unshifted: 0x3042))
    XCTAssertEqual(
      ControlKey.parse("shift+é"),
      char(
        "É", unshifted: 0xE9, mods: GHOSTTY_MODS_SHIFT.rawValue,
        consumed: GHOSTTY_MODS_SHIFT.rawValue))
  }
}
