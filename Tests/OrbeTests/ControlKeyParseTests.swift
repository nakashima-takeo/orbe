import GhosttyKit
import XCTest

@testable import Orbe

/// `ControlKey.parse` のうち、PTY に届くバイトでは観察しにくい規則を固定する。send_key が修飾を
/// 黙殺して素の文字を注入しない契約（cmd/super 付き単一文字・未知修飾・複数 scalar・制御文字は
/// 拒否）と、修飾の別名・大文字指定・非 ASCII の受理。名前付きキーや修飾の符号化は
/// `SurfaceKeyInputTests` が実 PTY のバイトで守る。
final class ControlKeyParseTests: OrbeTestCase {
  private func mods(_ raw: UInt32) -> ghostty_input_mods_e { ghostty_input_mods_e(rawValue: raw) }

  /// keycode 無しの単一文字入力。
  private func char(
    _ text: String, unshifted: UInt32, mods rawMods: UInt32 = 0, consumed rawConsumed: UInt32 = 0
  ) -> SurfaceKeyInput {
    SurfaceKeyInput(
      keycode: SurfaceKeyInput.noKeycode, text: text, unshiftedCodepoint: unshifted,
      mods: mods(rawMods), consumedMods: mods(rawConsumed))
  }

  func testPlainSingleChar() {
    XCTAssertEqual(ControlKey.parse("a"), char("a", unshifted: 0x61))
    // 大文字指定は lowercased（大文字は shift+a で明示する）。
    XCTAssertEqual(ControlKey.parse("A"), char("a", unshifted: 0x61))
  }

  /// alt の別名（option / opt / meta）は alt と同じ入力になる。
  func testAltAliasesParseAsAlt() throws {
    let alt = try XCTUnwrap(ControlKey.parse("alt+b"))
    for spec in ["option+b", "opt+b", "meta+b"] {
      XCTAssertEqual(ControlKey.parse(spec), alt, spec)
    }
  }

  /// 端末へ届く形を持たない指定は受けない。cmd/super 付き単一文字・未知修飾・空・名前付きキーで
  /// ない複数文字・複数 scalar の grapheme・制御文字（後二者は send_text の領分）。
  func testSpecsWithoutATerminalFormAreRejected() {
    for spec in [
      "cmd+c", "super+a", "hyper+a", "", "ctrl+", "abc", "👨‍👩‍👧", "\u{03}", "\u{7f}",
    ] {
      XCTAssertNil(ControlKey.parse(spec), spec.debugDescription)
    }
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
