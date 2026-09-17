import GhosttyKit
import XCTest

@testable import Orbe

/// OSC 8 リンク（端末出力が見えている文字列と別の対象を指せるリンク）を開く前の判定を固定する。
/// 判定は allow（Orbe が決めた開き先つき）/ confirm / block の 3 値。ローカルファイルの家族ごとの開き先は
/// `UntrustedLinkTests+Files.swift` が持ち、ファイル系は caseDir に置いた実ファイルで判定させる。
///
/// 壊れると何が起きるか: 端末出力が仕込んだアプリ・実行形式・転送ファイル・別ホストのファイル・不可視文字で
/// 偽装した URL が、⌘クリック 1 回で開かれる。実行ビット付きのスクリプトが Terminal などの実行系アプリに
/// 渡って実行される。逆に判定が厳しすぎると、`ls --hyperlink`・ripgrep が出す `file://<このMacのホスト名>/path` や
/// web リンクが開かなくなり、日常のファイルリンクが使えなくなる。`vscode://` 等が確認無しに開けば、任意の登録アプリが
/// 端末出力の意のままに起動する。
final class UntrustedLinkTests: OrbeTestCase {
  static let localHost = "orbe-test-host.local"

  var dir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    dir = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("links", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  // MARK: - web と mailto

  /// host のある http / https は、元の URL のまま URL の既定アプリで開く。
  func testWebLinkWithHostOpensAsIs() {
    XCTAssertEqual(
      decision("https://example.com/a?b=1#c"),
      .allow(.url(URL(string: "https://example.com/a?b=1#c")!)))
    XCTAssertEqual(decision("http://example.com"), .allow(.url(URL(string: "http://example.com")!)))
  }

  /// authority の無い web URL は、消費者ごとに解決が変わるので開かない。
  func testWebLinkWithoutHostIsBlocked() {
    XCTAssertEqual(decision("https:relative/path"), .block(.invalidWeb))
  }

  /// 宛先のある mailto は開き、宛先の無い mailto は開かない。
  func testMailtoOpensOnlyWithRecipient() {
    XCTAssertEqual(
      decision("mailto:a@example.com"), .allow(.url(URL(string: "mailto:a@example.com")!)))
    XCTAssertEqual(decision("mailto:"), .block(.malformed))
  }

  // MARK: - 独自 scheme

  /// web・mailto・file 以外の scheme は、開く前に人の確認を求める。
  func testCustomSchemeRequiresConfirmation() {
    XCTAssertEqual(
      decision("vscode://file/etc/hosts"), .confirm(URL(string: "vscode://file/etc/hosts")!))
    XCTAssertEqual(decision("man:ls"), .confirm(URL(string: "man:ls")!))
  }

  // MARK: - 不正形式と不可視文字

  /// scheme の無い文字列（相対参照・素のパス・空）は開かない。
  func testLinkWithoutSchemeIsBlockedAsMalformed() {
    XCTAssertEqual(decision("/etc/hosts"), .block(.malformed))
    XCTAssertEqual(decision("example.com/a"), .block(.malformed))
    XCTAssertEqual(decision(""), .block(.malformed))
  }

  /// 表示と実体を食い違わせうる文字（制御・書式・区切り・既定で無視される文字）を含む URL は、
  /// scheme が web でも独自でも開かない。
  func testLinkWithInvisibleCharactersIsBlocked() {
    for scalar in Self.invisibleScalars {
      for raw in ["https://example.com/a\(scalar)b", "vscode://file/a\(scalar)b"] {
        XCTAssertEqual(
          decision(raw), .block(.unsafeCharacters), "U+\(Self.hex(scalar)) in \(raw.prefix(8))")
      }
    }
  }

  /// 通常の空白・アクセント付き文字・日本語・絵文字は不可視文字として扱わない。
  func testLinkWithVisibleNonASCIICharactersIsNotBlocked() {
    for raw in [
      "vscode://file/a b", "vscode://file/café", "vscode://file/日本語", "vscode://file/🦊",
    ] {
      XCTAssertEqual(decision(raw), .confirm(URL(string: raw)!), raw)
    }
  }

  // MARK: - file の host

  /// host が空・localhost・このマシンの名前（大文字小文字を問わない）のファイルリンクは開く。
  func testFileLinkOnLocalHostIsAllowed() throws {
    let file = try makeFile("notes.txt")
    let path = file.path
    for raw in [
      "file://\(path)",
      "file://localhost\(path)",
      "file://\(Self.localHost)\(path)",
      "file://\(Self.localHost.uppercased())\(path)",
    ] {
      XCTAssertEqual(decision(raw), .allow(.text(canonical(file))), raw)
    }
  }

  /// このマシンが実際に名乗るホスト名のファイルリンク（`ls --hyperlink` の出力形）は、既定の判定で開く。
  func testFileLinkWithThisMachinesHostNameIsAllowedByDefault() throws {
    let file = try makeFile("notes.txt")
    let raw = "file://\(ProcessInfo.processInfo.hostName)\(file.path)"
    XCTAssertEqual(UntrustedLink(raw).decision, .allow(.text(canonical(file))))
  }

  /// このマシン以外の host を指すファイルリンクは、同じパスのファイルがあっても開かない。
  func testFileLinkOnOtherHostIsBlocked() throws {
    let file = try makeFile("notes.txt")
    XCTAssertEqual(decision("file://other-host.local\(file.path)"), .block(.remoteFile))
  }

  /// query や fragment の付いたファイルリンクは開かない。
  func testFileLinkWithQueryOrFragmentIsBlockedAsMalformed() throws {
    let file = try makeFile("notes.txt")
    XCTAssertEqual(decision("file://\(file.path)?x=1"), .block(.malformed))
    XCTAssertEqual(decision("file://\(file.path)#L1"), .block(.malformed))
  }

  // MARK: - 表示文字列

  /// ファイルリンクの表示は、端末出力の綴りではなく開く実体のパス。
  func testFileLinkDisplaysResolvedPath() throws {
    let file = try makeFile("notes.txt")
    let link = dir.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertEqual(
      UntrustedLink("file://\(Self.localHost)\(link.path)", localHosts: [Self.localHost])
        .displayString,
      canonical(file).path)
  }

  /// ファイル以外のリンクは元の文字列を表示し、不可視文字は `\u{XXXX}` として見せる。
  func testNonFileLinkDisplaysRawTextWithInvisibleCharactersVisualized() {
    XCTAssertEqual(
      UntrustedLink("vscode://file/etc/hosts").displayString, "vscode://file/etc/hosts")
    for scalar in Self.invisibleScalars {
      XCTAssertEqual(
        UntrustedLink("https://example.com/a\(scalar)b").displayString,
        "https://example.com/a\\u{\(Self.hex(scalar))}b")
    }
    XCTAssertEqual(
      UntrustedLink("vscode://file/a b/café/🦊").displayString, "vscode://file/a b/café/🦊")
  }

  // MARK: - OSC 8 由来の識別

  /// libghostty が OSC 8 由来と伝えるリンクは、正規表現リンクと区別される（区別が消えると不信の判定を素通りする）。
  func testOSC8KindIsDistinguishedFromDetectedLinks() {
    XCTAssertEqual(OpenURL.Kind(GHOSTTY_ACTION_OPEN_URL_KIND_OSC8), .osc8)
    XCTAssertNotEqual(OpenURL.Kind(GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN), .osc8)
  }
}

// MARK: - Helpers

extension UntrustedLinkTests {
  /// ソフトハイフン・不可視の関数適用・モンゴル語母音区切り・ハングルの埋め字・異体字セレクタ・
  /// 結合書記素接合子・タグ文字・ゼロ幅空白・方向上書き・行区切り・ノーブレークスペース・C0/C1 制御・
  /// 私用領域・非文字（未割当）。
  static let invisibleScalars: [Unicode.Scalar] = [
    "\u{00AD}", "\u{2061}", "\u{180E}", "\u{3164}", "\u{FE0F}", "\u{034F}", "\u{E0041}",
    "\u{200B}", "\u{202E}", "\u{2028}", "\u{00A0}", "\u{0A}", "\u{85}", "\u{E000}", "\u{FFFF}",
  ]

  static func hex(_ scalar: Unicode.Scalar) -> String {
    String(format: "%04X", scalar.value)
  }

  func decision(_ raw: String) -> UntrustedLink.Decision {
    UntrustedLink(raw, localHosts: [Self.localHost]).decision
  }

  static let textContent = Data("content\n".utf8)
  /// UTF-8 としては正しいが NUL を含む（テキストと見なされない）中身。
  static let binaryContent = Data("\u{7F}ELF\u{0}\u{1}\u{0}".utf8)

  @discardableResult
  func makeFile(_ name: String, _ data: Data = textContent, executable: Bool = false) throws
    -> URL
  {
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    return url
  }

  func makeDirectory(_ name: String) throws -> URL {
    let url = dir.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func fileDecision(_ url: URL) -> UntrustedLink.Decision {
    decision("file://\(url.path)")
  }

  /// `..` と symlink を畳んだ実体（`/private` を剥がす Foundation の解決ではなく realpath(3) と同じ）。
  func canonical(_ url: URL) -> URL {
    let resolved = realpath(url.path, nil)!
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
  }
}
