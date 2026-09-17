import AppKit
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
  /// キー 1 打（press + release）を物理経路へ流し、PTY に `bytes` が届くことを見る。
  private func assertTyped(
    _ key: PhysicalKey, arrives bytes: String, in dump: TtyDumpTab,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    key.type(into: dump.tab.surface)
    XCTAssertEqual(
      dump.next(file: file, line: line), TtyDumpTab.hex(bytes),
      "物理キー \(key.unmodified)（characters \(TtyDumpTab.hex(key.characters))）の受信バイトが違う",
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
