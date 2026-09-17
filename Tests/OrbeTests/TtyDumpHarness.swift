import AppKit
import Carbon.HIToolbox
import Foundation
import XCTest

@testable import Orbe

/// タブの PTY へ届いた生バイトを観測する駆動台。テストクラスではない支援ファイルで、
/// `ControlProcessHarness` と同じ位置づけ。
///
/// タブに raw tty で読む dump プログラム（python3）を起こし、受信したバイト列を hex で画面へ
/// 書かせる。画面は `controlReadText` で読めるので、surface へ送ったキー入力が端末モード
/// （legacy / bracketed paste / kitty keyboard protocol）に応じてどんなバイトになったかを、
/// libghostty の符号化を通した実物で測れる。モードの切替（bracketed paste の有効化・kitty flags の
/// push）と、端末への要求（クリップボードの読み取り・書き込み）は dump 自身が READY の前に出す。
/// 画面はその前に scrollback ごと消し、READY から始まる dump の出力だけにする——タブは macOS では
/// `login(1)` 経由で起動し、その Last login バナーの有無は実行ユーザーのホームの `.hushlogin` で決まる。
///
/// 1 打ごとに `next()` で待ってから次を送る——連打すると dump の 1 回の read に複数打が合流し、
/// 打鍵単位の突き合わせができなくなる。
final class TtyDumpTab {
  /// `osc52Read` は OSC 52 の読み取り要求の直後に Kitty clipboard の読み取り要求を続けて出す。両者は
  /// libghostty の同じ経路（surface の mailbox → ホスト）を順に通り、Kitty 側は許可でも拒否でも必ず
  /// 応答するので、OSC 52 に応答があればそれより先に届く——応答が「無い」ことを待ち時間に頼らず測れる。
  /// `kittyWrite*` は Kitty clipboard の書き込みを 1 件（本文 `kittyWrittenText`）、モード名が示す MIME で出す。
  enum Mode: String {
    case legacy, paste, kitty, osc52Read, kittyRead, kittyReadPrimary
    case kittyWriteCharset, kittyWriteSpacedCharset
  }

  static let kittyWrittenText = "kitty-written"

  /// 1 打あたりの到達を待つ上限。実時間の検証ではなく、進まなくなったら諦めるための上限。
  static let keyTimeout: TimeInterval = 5

  private static let script = """
    import base64, os, sys, tty
    mode = sys.argv[1]
    def b64(text):
        return base64.b64encode(text.encode()).decode()
    def kitty_write(mime):
        return ("\\x1b]5522;type=write\\x1b\\\\"
            + "\\x1b]5522;type=wdata:mime=" + b64(mime) + ";" + b64("\(kittyWrittenText)") + "\\x1b\\\\"
            + "\\x1b]5522;type=wdata\\x1b\\\\")
    fd = sys.stdin.fileno()
    tty.setraw(fd)
    enter = {
        "legacy": "",
        "paste": "\\x1b[?2004h",
        "kitty": "\\x1b[>1u",
        "osc52Read": "\\x1b]52;c;?\\x07\\x1b]5522;type=read;dGV4dC9wbGFpbg==\\x1b\\\\",
        "kittyRead": "\\x1b]5522;type=read;dGV4dC9wbGFpbg==\\x1b\\\\",
        "kittyReadPrimary": "\\x1b]5522;type=read:loc=primary;dGV4dC9wbGFpbg==\\x1b\\\\",
        "kittyWriteCharset": kitty_write("text/plain;charset=utf-8"),
        "kittyWriteSpacedCharset": kitty_write("text/plain; charset=UTF-8"),
    }[mode]
    sys.stdout.write("\\x1b[H\\x1b[2J\\x1b[3J" + enter + "READY\\r\\n")
    sys.stdout.flush()
    while True:
        data = os.read(fd, 4096)
        if not data:
            break
        sys.stdout.write("GOT " + data.hex() + "\\r\\n")
        sys.stdout.flush()

    """

  /// dump のタブを 1 枚だけ持つ実 `WindowController`。タブ（surface と PTY）の寿命は window が
  /// 持つので、駆動台がここで抱えて自分と同時に畳む（`ControlProcess.target` と同じ形）。
  let controller: WindowController
  let tab: TerminalTab
  private var consumed = 0

  struct NotReady: Error {}

  /// `controller` のアクティブ workspace に dump のタブを開き、READY を待つ。
  init(
    in controller: WindowController, mode: Mode,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    self.controller = controller
    let scriptURL = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("ttydump.py")
    try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
    let tabId = try XCTUnwrap(
      controller.controlSpawn(
        workspaceId: nil, cwd: nil,
        command: "/usr/bin/python3 \(scriptURL.path) \(mode.rawValue)"),
      "dump のタブを開けない", file: file, line: line)
    tab = try XCTUnwrap(controller.controlResolveTab(tabId), file: file, line: line)
    let ready = ControlProcess.waitUntil(ControlProcess.tabSettleTimeout) {
      self.screen().contains("READY")
    }
    guard ready else {
      XCTFail("dump が READY にならない: \(screen())", file: file, line: line)
      throw NotReady()
    }
  }

  /// 次に届いたバイト列（`hex` と同じ表記）。`keyTimeout` まで待って届かなければ、画面ごと失敗を
  /// 記録して nil（符号化の違いではなく未着だと分かるように）。
  func next(file: StaticString = #filePath, line: UInt = #line) -> String? {
    guard
      ControlProcess.waitUntil(Self.keyTimeout, { self.received().count > self.consumed })
    else {
      XCTFail(
        "\(Self.keyTimeout) 秒で 1 バイトも届かない（受信済み \(consumed) 打）: \(screen())",
        file: file, line: line)
      return nil
    }
    defer { consumed += 1 }
    return received()[consumed]
  }

  /// 次に届いた `byteCount` バイト以上を、何回の read に分かれていても連結して返す（ペーストのように
  /// libghostty が複数回に分けて書く入力用）。届かなければ `next()` と同じく失敗を記録して nil。
  func next(bytes byteCount: Int, file: StaticString = #filePath, line: UInt = #line) -> String? {
    var joined = ""
    var taken = 0
    let arrived = ControlProcess.waitUntil(Self.keyTimeout) {
      let pending = self.received().dropFirst(self.consumed)
      joined = ""
      taken = 0
      for chunk in pending where joined.count < byteCount * 2 {
        joined += chunk
        taken += 1
      }
      return joined.count >= byteCount * 2
    }
    guard arrived else {
      XCTFail(
        "\(Self.keyTimeout) 秒で \(byteCount) バイト揃わない（届いたのは \(joined)）: \(screen())",
        file: file, line: line)
      return nil
    }
    consumed += taken
    return joined
  }

  /// 期待値の側を dump と同じ表記へ（`"\u{1b}[A"` → `"1b5b41"`）。
  static func hex(_ bytes: String) -> String {
    bytes.utf8.map { String(format: "%02x", $0) }.joined()
  }

  private func screen() -> String { tab.surface.controlReadText(scrollback: true) ?? "" }

  private func received() -> [String] {
    screen().split(separator: "\n").compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      return trimmed.hasPrefix("GOT ") ? String(trimmed.dropFirst(4)) : nil
    }
  }
}

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

  /// press と release を物理経路（`keyDown` / `keyUp`）へ流す。
  func type(into surface: SurfaceView) {
    surface.keyDown(with: event(.keyDown, in: surface.window))
    surface.keyUp(with: event(.keyUp, in: surface.window))
  }
}

extension OrbeTestCase {
  /// 層1 を本物の `app/orbe-defaults.conf` へ向け、プロセス級の ghostty config を読み直す。
  /// 後続のテストへ持ち越さないよう、終了時に外して読み直す。
  func stageCuratedDefaults() throws {
    let root = try XCTUnwrap(BundledResources.root)
    let staged = root.appendingPathComponent("orbe-defaults.conf")
    // このファイル: <repo>/Tests/OrbeTests/TtyDumpHarness.swift → 3 階層上が repo root。
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    try FileManager.default.copyItem(
      at: repoRoot.appendingPathComponent("app/orbe-defaults.conf"), to: staged)
    Ghostty.shared.reloadConfig()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: staged)
      Ghostty.shared.reloadConfig()
    }
  }

  /// 実 `WindowController` を起こし、0 タブの workspace に dump のタブを開く。controller の寿命は
  /// 返す `TtyDumpTab` が持つ——テストのローカル束縛が終わると window ごと畳まれ、タブと python が落ちる。
  func dump(_ mode: TtyDumpTab.Mode) throws -> TtyDumpTab {
    let fixture = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: [])])
    try JSONEncoder().encode(fixture).write(to: workspacesFile())
    return try TtyDumpTab(in: WindowController(), mode: mode)
  }
}
