import AppKit
import Carbon.HIToolbox
import XCTest

@testable import Orbe

/// 物理キー経路（`keyDown` → IME → `SurfaceKeyInput`）が `send_key` と同じバイトを届ける。
/// 値の組み立てと送出を `SurfaceKeyInput` / `sendKeyInput` に分けたので、物理経路の退行はここで見る。
///
/// 壊れると何が起きるか: キーボードで打った Ctrl+C が効かない、Option+B が `∫` になる、Enter が
/// 素の改行にならない——ユーザーの全入力が壊れるが、制御 API のテストは何も落とさない。
///
/// NSEvent は合成する。`characters(byApplyingModifiers:)` は keyCode をレイアウトで引き直すので、
/// 期待値は「kVK_ANSI_A が `a` を出す」ラテン系レイアウト（CI の US を含む）を前提にする。
extension SurfaceKeyInputTests {
  /// 物理キー 1 打の NSEvent 材料（macOS が US レイアウトで実際に組む値）。
  struct PhysicalKey {
    let keyCode: Int
    let characters: String
    let unmodified: String
    let modifiers: NSEvent.ModifierFlags

    static let a = PhysicalKey(keyCode: kVK_ANSI_A, characters: "a", unmodified: "a", modifiers: [])
    static let shiftA = PhysicalKey(
      keyCode: kVK_ANSI_A, characters: "A", unmodified: "A", modifiers: .shift)
    static let ctrlC = PhysicalKey(
      keyCode: kVK_ANSI_C, characters: "\u{03}", unmodified: "c", modifiers: .control)
    static let enter = PhysicalKey(
      keyCode: kVK_Return, characters: "\r", unmodified: "\r", modifiers: [])
    static let optionB = PhysicalKey(
      keyCode: kVK_ANSI_B, characters: "∫", unmodified: "b", modifiers: .option)
    static let shiftBackspace = PhysicalKey(
      keyCode: kVK_Delete, characters: "\u{7f}", unmodified: "\u{7f}", modifiers: .shift)
    static let optionBackspace = PhysicalKey(
      keyCode: kVK_Delete, characters: "\u{7f}", unmodified: "\u{7f}", modifiers: .option)

    func event(_ kind: NSEvent.EventType, in window: NSWindow?) -> NSEvent {
      NSEvent.keyEvent(
        with: kind, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window?.windowNumber ?? 0, context: nil,
        characters: characters, charactersIgnoringModifiers: unmodified, isARepeat: false,
        keyCode: UInt16(keyCode))!
    }
  }

  /// キー 1 打（press + release）を物理経路へ流し、PTY に `bytes` が届くことを見る。
  private func assertTyped(
    _ key: PhysicalKey, arrives bytes: String, in dump: TtyDumpPane,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    dump.pane.keyDown(with: key.event(.keyDown, in: dump.pane.window))
    dump.pane.keyUp(with: key.event(.keyUp, in: dump.pane.window))
    XCTAssertEqual(
      dump.next(file: file, line: line), TtyDumpPane.hex(bytes),
      "物理キー \(key.unmodified)（characters \(TtyDumpPane.hex(key.characters))）の受信バイトが違う",
      file: file, line: line)
  }

  /// `a` / Shift+A / Ctrl+C / Enter / Option+B が legacy で `send_key` と同じバイトになる。
  /// Option+B は層1 の `macos-option-as-alt = true` により `∫` でなく ESC 前置の `b` になる。
  func testPhysicalKeysArriveAsSameBytesAsSendKey() throws {
    let dump = try dump(.legacy)
    assertTyped(.a, arrives: "a", in: dump)
    assertTyped(.shiftA, arrives: "A", in: dump)
    assertTyped(.ctrlC, arrives: "\u{03}", in: dump)
    assertTyped(.enter, arrives: "\r", in: dump)
    assertTyped(.optionB, arrives: "\u{1b}b", in: dump)
  }

  /// kitty keyboard protocol 下で Shift+Backspace / Option+Backspace の修飾が CSI u（`127;2u` /
  /// `127;3u`）で届く。Shift+Backspace が DEL ガードの回帰検知——text（DEL）が key に乗ると consumed_mods
  /// が shift を差し引き、素の DEL に潰れる。Option+Backspace は層1 既定（`macos-option-as-alt = true`）
  /// では consumed に alt が入らずガード無しでも通るので、物理経路が kitty 下で `127;3u` で届くこと
  /// 自体の固定。
  func testPhysicalModifiedBackspaceKeepsModifiersUnderKittyProtocol() throws {
    let dump = try dump(.kitty)
    assertTyped(.shiftBackspace, arrives: "\u{1b}[127;2u", in: dump)
    assertTyped(.optionBackspace, arrives: "\u{1b}[127;3u", in: dump)
  }
}
