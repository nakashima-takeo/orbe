import GhosttyKit
import XCTest

@testable import Orbe

/// `ControlKey.parse` の全分岐を固定する。send_key が修飾を黙殺して素の文字を注入しない契約を守る。
/// libghostty 非依存（keycode/mods 定数の値だけを参照）。
final class ControlKeyParseTests: XCTestCase {
  /// .text の中身を取り出す（一致しなければ nil）。ControlKey は Equatable を持たないためのヘルパー。
  private func text(_ key: ControlKey?) -> String? {
    if case .text(let s) = key { return s }
    return nil
  }

  /// .special の (keycode, mods.rawValue) を取り出す。
  private func special(_ key: ControlKey?) -> (UInt32, UInt32)? {
    if case .special(let code, let mods) = key { return (code, mods.rawValue) }
    return nil
  }

  func testSpecialKeys() {
    XCTAssertEqual(special(ControlKey.parse("enter"))?.0, 36)
    XCTAssertEqual(special(ControlKey.parse("up"))?.0, 126)
    // 修飾なし special は mods 0。
    XCTAssertEqual(special(ControlKey.parse("enter"))?.1, 0)
  }

  func testPlainSingleChar() {
    XCTAssertEqual(text(ControlKey.parse("a")), "a")
  }

  func testCtrlFoldsToC0() {
    XCTAssertEqual(text(ControlKey.parse("ctrl+c")), "\u{03}")
    XCTAssertEqual(text(ControlKey.parse("ctrl+a")), "\u{01}")
  }

  func testAltFoldsToEscPrefix() {
    XCTAssertEqual(text(ControlKey.parse("alt+b")), "\u{1b}b")
    // option / meta も同じ ESC プレフィックス。
    XCTAssertEqual(text(ControlKey.parse("option+b")), "\u{1b}b")
    XCTAssertEqual(text(ControlKey.parse("meta+f")), "\u{1b}f")
  }

  func testCtrlOutsideC0Rejected() {
    // 'ctrl+1' は C0 レンジ外なので拒否（黙って '1' を注入しない）。
    XCTAssertNil(ControlKey.parse("ctrl+1"))
  }

  func testSuperHasNoTerminalByte() {
    // cmd/super は端末バイト表現を持たないため単一文字では拒否。
    XCTAssertNil(ControlKey.parse("cmd+c"))
    XCTAssertNil(ControlKey.parse("super+a"))
  }

  func testUnknownModifierRejected() {
    XCTAssertNil(ControlKey.parse("hyper+a"))
  }

  func testEmptyAndMultiChar() {
    XCTAssertNil(ControlKey.parse(""))
    // 特殊キー名でない複数文字は拒否。
    XCTAssertNil(ControlKey.parse("abc"))
  }

  func testModifierCompositionOnSpecial() {
    let parsed = special(ControlKey.parse("cmd+shift+up"))
    XCTAssertEqual(parsed?.0, 126)
    XCTAssertEqual(parsed?.1, GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
  }
}
