import AppKit
import Carbon.HIToolbox
import XCTest

@testable import Orbe

/// 端末とシステムのクリップボード（`NSPasteboard.general`）の往来を、実 libghostty と実タブの PTY で固定する。
/// ユーザー発の ⌘V / ⌘⇧V / ⌘C・選択・中クリックは通り、端末アプリ発の読み取り（OSC 52 / Kitty clipboard）は
/// クリップボードの中身に関わらず拒否される。端末アプリ発の書き込みはテキスト表現だけが入る。
///
/// 壊れると何が起きるか: ⌘V で何も貼れない・⌘C でコピーできない・選択しただけではコピーされない・
/// 中クリックが無反応になる（libghostty の契約や既定値が変わるとホストのコールバックが静かに空振りする）。
/// 端末アプリが書いたテキストが、MIME に charset が付くだけで黙って捨てられる。あるいは端末で動く任意のプログラムが、ユーザーの
/// クリップボード（パスワード等）を黙って読み出せる。中身の有無で応答が変わるだけでも、
/// 「クリップボードに文字列があるか」が端末アプリへ漏れる。
///
/// 層1（`app/orbe-defaults.conf`）を本物のまま読み込む。読み取りの拒否はそこにある
/// `clipboard-read = deny` が担う。`NSPasteboard.general` はハーネスが隔離しないシステム全域の
/// 状態なので、テストが書き換える前の中身を `tearDown` で戻す。
final class SurfaceClipboardTests: OrbeTestCase {
  private static let secret = "clipboard-secret"

  private var savedPasteboard: [NSPasteboardItem] = []

  override func setUpWithError() throws {
    try super.setUpWithError()
    try stageCuratedDefaults()
    savedPasteboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) { copy.setData(data, forType: type) }
      }
      return copy
    }
  }

  override func tearDown() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects(savedPasteboard)
    super.tearDown()
  }

  private func setClipboard(_ text: String?) {
    NSPasteboard.general.clearContents()
    if let text { NSPasteboard.general.setString(text, forType: .string) }
  }

  private static let commandA = PhysicalKey(
    keyCode: kVK_ANSI_A, characters: "a", unmodified: "a", modifiers: .command)
  private static let commandC = PhysicalKey(
    keyCode: kVK_ANSI_C, characters: "c", unmodified: "c", modifiers: .command)
  private static let commandV = PhysicalKey(
    keyCode: kVK_ANSI_V, characters: "v", unmodified: "v", modifiers: .command)
  private static let commandShiftV = PhysicalKey(
    keyCode: kVK_ANSI_V, characters: "V", unmodified: "V", modifiers: [.command, .shift])

  private static func middleClick(into surface: SurfaceView) throws {
    let center = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
    for type in [CGEventType.otherMouseDown, .otherMouseUp] {
      let cgEvent = try XCTUnwrap(
        CGEvent(
          mouseEventSource: nil, mouseType: type, mouseCursorPosition: center,
          mouseButton: .center))
      let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
      if type == .otherMouseDown {
        surface.otherMouseDown(with: event)
      } else {
        surface.otherMouseUp(with: event)
      }
    }
  }

  // MARK: - ユーザー発

  /// bracketed paste 下の ⌘V で、クリップボードの複数行・日本語の文字列がそのままペースト枠に包まれて届く。
  func testCommandVPastesClipboardTextInBracketedPaste() throws {
    let dump = try dump(.paste)
    setClipboard("日本語\nsecond line")

    Self.commandV.type(into: dump.tab.surface)

    let expected = TtyDumpTab.hex("\u{1b}[200~日本語\nsecond line\u{1b}[201~")
    XCTAssertEqual(dump.next(bytes: expected.count / 2), expected)
  }

  /// bracketed paste 無しの複数行（libghostty が確認を求める危険なペースト）も、⌘V なら確認無しで届く。
  func testCommandVPastesMultiLineTextWithoutBracketedPaste() throws {
    let dump = try dump(.legacy)
    setClipboard("日本語\nsecond line")

    Self.commandV.type(into: dump.tab.surface)

    let expected = TtyDumpTab.hex("日本語\rsecond line")
    XCTAssertEqual(dump.next(bytes: expected.count / 2), expected)
  }

  /// 選択の後にクリップボードが別の文字列へ変わっていても、⌘C で画面の選択がクリップボードの文字列を置き換える。
  func testCommandCCopiesSelectionToClipboard() throws {
    let dump = try dump(.legacy)
    Self.commandA.type(into: dump.tab.surface)
    setClipboard("after select")

    Self.commandC.type(into: dump.tab.surface)

    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "READY")
  }

  /// ⌘A で選択するだけで、⌘C を押さなくても選択がクリップボードの文字列を置き換える。
  func testSelectingAloneCopiesSelectionToClipboard() throws {
    let dump = try dump(.legacy)
    setClipboard("before select")

    Self.commandA.type(into: dump.tab.surface)

    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "READY")
  }

  /// 中クリックで、クリップボードの文字列がペーストされる。
  func testMiddleClickPastesClipboardText() throws {
    let dump = try dump(.legacy)
    setClipboard("middle-click paste")

    try Self.middleClick(into: dump.tab.surface)

    XCTAssertEqual(dump.next(), TtyDumpTab.hex("middle-click paste"))
  }

  /// ⌘⇧V（選択クリップボードからのペースト）も、クリップボードの文字列をペーストする。
  func testCommandShiftVPastesClipboardText() throws {
    let dump = try dump(.legacy)
    setClipboard("selection paste")

    Self.commandShiftV.type(into: dump.tab.surface)

    XCTAssertEqual(dump.next(), TtyDumpTab.hex("selection paste"))
  }

  // MARK: - 端末アプリ発

  /// OSC 52 の読み取り要求には、クリップボードに文字列があっても空でも何も返らない。
  /// 応答が無いことは、後続の Kitty 読み取り要求への応答が最初に届くバイトであることで見る。
  func testOSC52ReadGetsNoResponseRegardlessOfClipboard() throws {
    for clipboard in [Self.secret, nil] {
      setClipboard(clipboard)
      let dump = try dump(.osc52Read)

      let first = dump.next() ?? ""

      XCTAssertTrue(
        first.hasPrefix(TtyDumpTab.hex("\u{1b}]5522;")),
        "クリップボード \(clipboard ?? "空") で OSC 52 に応答が返った: \(first)")
    }
  }

  /// Kitty clipboard の読み取り要求には、クリップボードに文字列があっても空でも拒否（EPERM）だけが返る。
  func testKittyClipboardReadIsDeniedRegardlessOfClipboard() throws {
    for clipboard in [Self.secret, nil] {
      setClipboard(clipboard)
      let dump = try dump(.kittyRead)

      XCTAssertEqual(
        dump.next(), TtyDumpTab.hex("\u{1b}]5522;type=read:status=EPERM\u{1b}\\"),
        "クリップボード \(clipboard ?? "空") で拒否以外が返った")
    }
  }

  /// ユーザー設定で読み取りを許しても、PRIMARY（選択クリップボード）の読み取りには非対応（ENOSYS）が返り、
  /// クリップボードの中身は渡らない。
  func testKittyPrimaryReadIsUnsupportedEvenWhenReadsAllowed() throws {
    let userConfig = try XCTUnwrap(Config.userFileURLOverride)
    try "clipboard-read = allow\n".write(to: userConfig, atomically: true, encoding: .utf8)
    addTeardownBlock { try? FileManager.default.removeItem(at: userConfig) }
    Ghostty.shared.reloadConfig()
    setClipboard(Self.secret)

    let dump = try dump(.kittyReadPrimary)

    XCTAssertEqual(dump.next(), TtyDumpTab.hex("\u{1b}]5522;type=read:status=ENOSYS\u{1b}\\"))
  }

  /// Kitty clipboard の書き込みで charset 付きの MIME（`text/plain;charset=utf-8`）で書かれたテキストが、
  /// クリップボードの文字列になる。
  func testKittyWriteWithCharsetMimeSetsClipboardText() throws {
    setClipboard("before write")
    let dump = try dump(.kittyWriteCharset)

    XCTAssertEqual(dump.next(), Self.kittyWriteDone)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), TtyDumpTab.kittyWrittenText)
  }

  /// macOS がテキストと解さない MIME（`;` の後に空白が入る `text/plain; charset=UTF-8`）だけの書き込みは、
  /// クリップボードを変えない。
  func testKittyWriteWithoutTextRepresentationLeavesClipboardUnchanged() throws {
    setClipboard("before write")
    let dump = try dump(.kittyWriteSpacedCharset)

    XCTAssertEqual(dump.next(), Self.kittyWriteDone)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "before write")
  }

  private static let kittyWriteDone = TtyDumpTab.hex("\u{1b}]5522;type=write:status=DONE\u{1b}\\")
}
