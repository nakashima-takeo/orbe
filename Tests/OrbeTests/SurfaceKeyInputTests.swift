import AppKit
import XCTest

@testable import Orbe

/// `send_key` が解決した `SurfaceKeyInput` を実 libghostty に符号化させ、タブの PTY へ届く
/// **バイト列**で固定する。端末モード（legacy / bracketed paste / kitty keyboard protocol）ごとの
/// 符号化は libghostty に一任しているので、Orbe が渡す値の形（keycode 無しの単一文字・text /
/// unshifted / mods / consumed_mods）が少しでもずれると、ここでしか現れない。
///
/// 壊れると何が起きるか: エージェントが `send_key ctrl+c` で対話プロセスを止められない、
/// `alt+b` が素の `b` として入力される、bracketed paste 有効なアプリ（zsh 等）でキーがペースト枠に
/// 包まれて無視される、kitty protocol のアプリ（neovim 等）で修飾が落ちる——どれも制御 API は
/// `ok: true` を返し続けるので、呼び手からは「送ったのに効かない」としか見えない。
///
/// 層1（`app/orbe-defaults.conf`）を本物のまま読み込む。legacy の `alt+<文字>` の ESC 前置は
/// そこにある `macos-option-as-alt = true` に依存し、無ければレイアウト次第で素の文字になる。
///
/// 重要: 実 NSWindow に SurfaceView を接続し、実タブで dump プログラムを走らせる（GhosttyKit 必須）。
final class SurfaceKeyInputTests: OrbeTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    try stageCuratedDefaults()
  }

  /// 層1 を本物の `app/orbe-defaults.conf` へ向け、プロセス級の ghostty config を読み直す。
  /// 後続のテストへ持ち越さないよう、終了時に外して読み直す。
  private func stageCuratedDefaults() throws {
    let root = try XCTUnwrap(BundledResources.root)
    let staged = root.appendingPathComponent("orbe-defaults.conf")
    try FileManager.default.copyItem(
      at: repoRoot().appendingPathComponent("app/orbe-defaults.conf"), to: staged)
    Ghostty.shared.reloadConfig()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: staged)
      Ghostty.shared.reloadConfig()
    }
  }

  /// このファイル: <repo>/Tests/OrbeTests/...swift → 3 階層上が repo root。
  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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

  /// `send_key spec` を送り、PTY に `bytes` が 1 打として届くことを見る。
  private func assertSendKey(
    _ spec: String, arrives bytes: String, in dump: TtyDumpTab,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    dump.tab.surface.controlSendKey(
      try XCTUnwrap(ControlKey.parse(spec), "\(spec) が解決できない", file: file, line: line))
    XCTAssertEqual(
      dump.next(file: file, line: line), TtyDumpTab.hex(bytes),
      "send_key \(spec) の受信バイトが違う", file: file, line: line)
  }

  // MARK: - 層1 の既定

  /// `app/orbe-defaults.conf` は `macos-option-as-alt = true` を持つ。legacy の `alt+<文字>` は
  /// この値に依存し、未設定だと libghostty がキーボードレイアウトで自動判定する（true になるのは
  /// `com.apple.keylayout.US` / `USInternational` だけ。ABC も false）。
  /// 上のバイト検証は US レイアウトの機（CI を含む）では未設定でも通ってしまうので、行そのものを見る。
  func testCuratedDefaultsEncodeOptionAsAlt() throws {
    let defaults = try String(
      contentsOf: repoRoot().appendingPathComponent("app/orbe-defaults.conf"), encoding: .utf8)
    XCTAssertTrue(
      defaults.split(separator: "\n").contains("macos-option-as-alt = true"),
      "app/orbe-defaults.conf に macos-option-as-alt = true が無い（US / USInternational 以外で alt+<文字> が素の文字になる）"
    )
  }

  // MARK: - legacy（bracketed paste 無し・kitty 無し）

  /// 単一文字: ctrl は C0 へ折り畳まれ、alt は ESC 前置、shift は大文字化、space は空白が届く。
  func testLegacyEncodesSingleChars() throws {
    let dump = try dump(.legacy)
    try assertSendKey("ctrl+c", arrives: "\u{03}", in: dump)
    try assertSendKey("ctrl+u", arrives: "\u{15}", in: dump)
    try assertSendKey("alt+b", arrives: "\u{1b}b", in: dump)
    try assertSendKey("space", arrives: " ", in: dump)
    try assertSendKey("shift+a", arrives: "A", in: dump)
    try assertSendKey("a", arrives: "a", in: dump)
  }

  /// 名前付きキーは keycode から符号化される（修飾は CSI パラメータ / ESC 前置に載る）。
  func testLegacyEncodesNamedKeys() throws {
    let dump = try dump(.legacy)
    try assertSendKey("enter", arrives: "\r", in: dump)
    try assertSendKey("up", arrives: "\u{1b}[A", in: dump)
    try assertSendKey("ctrl+up", arrives: "\u{1b}[1;5A", in: dump)
    try assertSendKey("shift+tab", arrives: "\u{1b}[Z", in: dump)
    try assertSendKey("escape", arrives: "\u{1b}", in: dump)
    try assertSendKey("alt+enter", arrives: "\u{1b}\r", in: dump)
  }

  // MARK: - bracketed paste 有効

  /// キーはペースト枠（`ESC[200~` / `ESC[201~`）に包まれず、legacy と同じバイトが届く。
  func testBracketedPasteDoesNotWrapKeys() throws {
    let dump = try dump(.paste)
    try assertSendKey("ctrl+c", arrives: "\u{03}", in: dump)
    try assertSendKey("alt+b", arrives: "\u{1b}b", in: dump)
    try assertSendKey("space", arrives: " ", in: dump)
    try assertSendKey("enter", arrives: "\r", in: dump)
  }

  // MARK: - kitty keyboard protocol

  /// 修飾付きは CSI u（`<codepoint>;<mods>u`）で届き、修飾が落ちない。shift は大文字化が起きた
  /// ときだけ消費されるので、`shift+a` は `A` の文字として、`shift+1` は shift 付きの `1` として届く。
  func testKittyProtocolEncodesModifiedKeysAsCSIu() throws {
    let dump = try dump(.kitty)
    try assertSendKey("ctrl+c", arrives: "\u{1b}[99;5u", in: dump)
    try assertSendKey("alt+b", arrives: "\u{1b}[98;3u", in: dump)
    try assertSendKey("ctrl+enter", arrives: "\u{1b}[13;5u", in: dump)
    try assertSendKey("shift+a", arrives: "A", in: dump)
    try assertSendKey("shift+1", arrives: "\u{1b}[49;2u", in: dump)
  }
}
