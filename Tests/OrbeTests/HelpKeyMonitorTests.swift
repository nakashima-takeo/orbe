import AppKit
import XCTest

@testable import Orbe

/// ヘルプのキーボード可視化のイベント解決（NSEvent → キー id / 修飾同期）を固定する。
/// 特に「⌘ 解放で非修飾キーの残留を全クリア」（macOS は ⌘ 押下中の他キー keyUp を配らない）が要。
final class HelpKeyMonitorTests: XCTestCase {
  private func key(_ chars: String, type: NSEvent.EventType = .keyDown) -> NSEvent {
    NSEvent.keyEvent(
      with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
      keyCode: 0)!
  }

  private func flags(_ modifierFlags: NSEvent.ModifierFlags, raw: UInt = 0) -> NSEvent {
    NSEvent.keyEvent(
      with: .flagsChanged, location: .zero,
      modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlags.rawValue | raw),
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 0)!
  }

  func testKeyIDResolvesCharactersAndSpecialKeys() {
    XCTAssertEqual(HelpKeyMonitor.keyID(for: key("h")), "h")
    XCTAssertEqual(HelpKeyMonitor.keyID(for: key("T")), "t")
    XCTAssertEqual(HelpKeyMonitor.keyID(for: key("0")), "0")
    XCTAssertEqual(HelpKeyMonitor.keyID(for: key("/")), "/")
    XCTAssertEqual(HelpKeyMonitor.keyID(for: key(" ")), "space")
    XCTAssertEqual(HelpKeyMonitor.keyID(for: key("\u{1b}")), "esc")
    XCTAssertEqual(HelpKeyMonitor.keyID(for: key("\t")), "tab")
    XCTAssertEqual(HelpKeyMonitor.keyID(for: key("\r")), "return")
    // ↑↓ は ud に合流、←→ は独立。
    func arrow(_ k: NSEvent.SpecialKey) -> NSEvent { key(String(UnicodeScalar(k.rawValue)!)) }
    XCTAssertEqual(HelpKeyMonitor.keyID(for: arrow(.upArrow)), "ud")
    XCTAssertEqual(HelpKeyMonitor.keyID(for: arrow(.downArrow)), "ud")
    XCTAssertEqual(HelpKeyMonitor.keyID(for: arrow(.leftArrow)), "left")
    XCTAssertEqual(HelpKeyMonitor.keyID(for: arrow(.rightArrow)), "right")
    // F キーは可視化対象外。
    XCTAssertNil(HelpKeyMonitor.keyID(for: arrow(.f1)))
  }

  func testSyncingModifiersDistinguishesLeftRight() {
    // 左 ⌘ 押下（device マスク 0x0008）。
    let leftCmd = flags(.command, raw: 0x0008)
    var pressed = HelpKeyMonitor.syncingModifiers([], with: leftCmd)
    XCTAssertEqual(pressed, ["cmd"])
    // 右 ⇧ 追加（device マスク 0x0004）。
    let addRShift = flags([.command, .shift], raw: 0x0008 | 0x0004)
    pressed = HelpKeyMonitor.syncingModifiers(pressed, with: addRShift)
    XCTAssertEqual(pressed, ["cmd", "rshift"])
  }

  func testCommandReleaseClearsResidualKeys() {
    // ⌘T 押下中（t の keyUp は ⌘ 押下中は配られない）→ ⌘ 解放で t の残留を全クリア。
    let pressed: Set<String> = ["cmd", "t"]
    let released = HelpKeyMonitor.syncingModifiers(pressed, with: flags([]))
    XCTAssertEqual(released, [])
  }

  func testCommandReleaseKeepsHeldModifiers() {
    // ⌘⇧ 押下から ⌘ だけ離す → ⇧ は flags に残っているので点灯を維持し、非修飾キーだけ落ちる。
    let pressed: Set<String> = ["cmd", "shift", "t"]
    let released = HelpKeyMonitor.syncingModifiers(pressed, with: flags(.shift, raw: 0x0002))
    XCTAssertEqual(released, ["shift"])
  }
}
