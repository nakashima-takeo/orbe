import AppKit
import Carbon.HIToolbox
import XCTest

@testable import Orbe

/// 端末とクリップボード（`Ghostty.pasteboard`）の往来を、実 libghostty と実タブの PTY で固定する。
/// ユーザー発の ⌘V / ⌘⇧V / ⌘C・選択・中クリックは通り、端末アプリ発の読み取り（OSC 52 / Kitty clipboard）は
/// クリップボードの中身に関わらず拒否される。端末アプリ発の書き込みはテキスト表現だけが入り、確認を求める
/// 設定では入らない。
///
/// 壊れると何が起きるか: ⌘V で何も貼れない・⌘C でコピーできない・選択しただけではコピーされない・
/// 中クリックが無反応になる（libghostty の契約や既定値が変わるとホストのコールバックが静かに空振りする）。
/// 端末アプリが書いたテキストが `text/plain;charset=utf-8` で黙って捨てられる。逆に、macOS がテキストと解さない
/// MIME（`;` の後に空白を入れた `text/plain; charset=UTF-8`）の書き込みでクリップボードが消える——Orbe は MIME を自前で
/// 分解せず判定を macOS の型解決に委ねる境界を固定している。あるいは端末で動く任意のプログラムが、ユーザーの
/// クリップボード（パスワード等）を黙って読み出せる——`clipboard-read = ask` にしたユーザーでは、確認の拒否が
/// 唯一の防壁になる。中身の有無で応答が変わるだけでも、「クリップボードに文字列があるか」が端末アプリへ漏れる。
///
/// 層1（`app/orbe-defaults.conf`）を本物のまま読み込む。読み取りの拒否はそこにある
/// `clipboard-read = deny` が担う。クリップボードはハーネスがテストごとの一意名の pasteboard へ向けている。
final class SurfaceClipboardTests: OrbeTestCase {
  private static let secret = "clipboard-secret"

  override func setUpWithError() throws {
    try super.setUpWithError()
    try stageCuratedDefaults()
  }

  private var clipboard: String? { Ghostty.pasteboard.string(forType: .string) }

  private func setClipboard(_ text: String?) {
    Ghostty.pasteboard.clearContents()
    if let text { Ghostty.pasteboard.setString(text, forType: .string) }
  }

  /// ghostty の user 層に書いて読み直す。
  private func useUserConfig(_ contents: String) throws {
    let userConfig = try XCTUnwrap(Config.userFileURLOverride)
    try contents.write(to: userConfig, atomically: true, encoding: .utf8)
    addTeardownBlock { try? FileManager.default.removeItem(at: userConfig) }
    Ghostty.shared.reloadConfig()
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

    XCTAssertEqual(clipboard, "READY")
  }

  /// ⌘A で選択するだけで、⌘C を押さなくても選択がクリップボードの文字列を置き換える。
  func testSelectingAloneCopiesSelectionToClipboard() throws {
    let dump = try dump(.legacy)
    setClipboard("before select")

    Self.commandA.type(into: dump.tab.surface)

    XCTAssertEqual(clipboard, "READY")
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
    for contents in [Self.secret, nil] {
      setClipboard(contents)
      let dump = try dump(.osc52Read)

      let first = dump.next() ?? ""

      XCTAssertTrue(
        first.hasPrefix(TtyDumpTab.hex("\u{1b}]5522;")),
        "クリップボード \(contents ?? "空") で OSC 52 に応答が返った: \(first)")
    }
  }

  /// Kitty clipboard の読み取り要求には、クリップボードに文字列があっても空でも拒否（EPERM）だけが返る。
  func testKittyClipboardReadIsDeniedRegardlessOfClipboard() throws {
    for contents in [Self.secret, nil] {
      setClipboard(contents)
      let dump = try dump(.kittyRead)

      XCTAssertEqual(
        dump.next(), Self.kittyReadDenied, "クリップボード \(contents ?? "空") で拒否以外が返った")
    }
  }

  /// ユーザー設定で読み取りを許しても、PRIMARY（選択クリップボード）の読み取りには非対応（ENOSYS）が返り、
  /// クリップボードの中身は渡らない。
  func testKittyPrimaryReadIsUnsupportedEvenWhenReadsAllowed() throws {
    try useUserConfig("clipboard-read = allow\n")
    setClipboard(Self.secret)

    let dump = try dump(.kittyReadPrimary)

    XCTAssertEqual(dump.next(), TtyDumpTab.hex("\u{1b}]5522;type=read:status=ENOSYS\u{1b}\\"))
  }

  /// 読み取りに確認を求める設定（`clipboard-read = ask`）でも、確認で拒否するので OSC 52 の読み取りに
  /// クリップボードの中身は渡らず、続く Kitty の読み取りには拒否（EPERM）が返る。
  func testReadsRequiringConfirmationAreDenied() throws {
    try useUserConfig("clipboard-read = ask\n")
    setClipboard(Self.secret)
    let dump = try dump(.osc52Read)

    var received = ""
    while !received.contains(Self.kittyReadDenied), let chunk = dump.next() {
      received += chunk
    }

    XCTAssertTrue(received.contains(Self.kittyReadDenied), received)
    let leaked = TtyDumpTab.hex(Data(Self.secret.utf8).base64EncodedString())
    XCTAssertFalse(received.contains(leaked), "OSC 52 の応答に中身が渡った: \(received)")
  }

  /// 書き込みに確認を求める設定（`clipboard-write = ask`）では、OSC 52 の書き込みはクリップボードを変えない。
  /// 確認を求めない設定の同じ書き込みはクリップボードの文字列になる（書き込みの処理を待てている対照）。
  func testOSC52WriteRequiringConfirmationLeavesClipboardUnchanged() throws {
    for (setting, expected) in [
      ("allow", TtyDumpTab.osc52WrittenText), ("ask", "before write"),
    ] {
      try useUserConfig("clipboard-write = \(setting)\n")
      setClipboard("before write")
      let dump = try dump(.osc52Write)

      XCTAssertEqual(dump.next(), Self.kittyReadDenied, setting)
      XCTAssertEqual(clipboard, expected, setting)
    }
  }

  /// Kitty clipboard の書き込みで charset 付きの MIME（`text/plain;charset=utf-8`）で書かれたテキストが、
  /// クリップボードの文字列になる。
  func testKittyWriteWithCharsetMimeSetsClipboardText() throws {
    setClipboard("before write")
    let dump = try dump(.kittyWriteCharset)

    XCTAssertEqual(dump.next(), Self.kittyWriteDone)
    XCTAssertEqual(clipboard, TtyDumpTab.kittyWrittenText)
  }

  /// RFC 上はテキストでも macOS がテキストと解さない MIME（`;` の後に空白が入る `text/plain; charset=UTF-8`）
  /// だけの書き込みは、クリップボードを変えない。Orbe は MIME を自前で分解せず、判定を macOS の型解決に
  /// 委ねる——その境界をここで固定する。
  func testKittyWriteWithMimeMacOSDoesNotResolveAsTextLeavesClipboardUnchanged() throws {
    setClipboard("before write")
    let dump = try dump(.kittyWriteSpacedCharset)

    XCTAssertEqual(dump.next(), Self.kittyWriteDone)
    XCTAssertEqual(clipboard, "before write")
  }

  /// macOS がテキストと解しても UTF-16 系の plain text（`text/plain;charset=utf-16`）だけの書き込みは、
  /// クリップボードを変えない（UTF-16 の本文を UTF-8 として読んだ NUL 混じりの文字列を置かない）。
  func testKittyWriteWithUTF16MimeLeavesClipboardUnchanged() throws {
    setClipboard("before write")
    let dump = try dump(.kittyWriteUTF16)

    XCTAssertEqual(dump.next(), Self.kittyWriteDone)
    XCTAssertEqual(clipboard, "before write")
  }

  private static let kittyReadDenied = TtyDumpTab.hex(
    "\u{1b}]5522;type=read:status=EPERM\u{1b}\\")
  private static let kittyWriteDone = TtyDumpTab.hex("\u{1b}]5522;type=write:status=DONE\u{1b}\\")
}
