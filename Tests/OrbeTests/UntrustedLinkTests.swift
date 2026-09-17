import GhosttyKit
import XCTest

@testable import Orbe

/// OSC 8 リンク（端末出力が見えている文字列と別の対象を指せるリンク）を開く前の allow / confirm / block 判定を固定する。
/// ファイル系は caseDir に置いた実ファイルで判定させる。
///
/// 壊れると何が起きるか: 端末出力が仕込んだ `file:///…/x.command`・アプリ・実行形式・転送ファイル・別ホストの
/// ファイル・不可視文字で偽装した URL が、⌘クリック 1 回で Launch Services の handler に渡り実行される。
/// 逆に判定が厳しすぎると、`ls --hyperlink`・ripgrep が出す `file://<このMacのホスト名>/path` や web リンクが
/// 開かなくなり、日常のファイルリンクが使えなくなる。`vscode://` 等が確認無しに開けば、任意の登録アプリが
/// 端末出力の意のままに起動する。
final class UntrustedLinkTests: OrbeTestCase {
  private static let localHost = "orbe-test-host.local"

  private var dir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    dir = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("links", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  // MARK: - web と mailto

  /// host のある http / https は、元の URL のまま開く。
  func testWebLinkWithHostIsAllowedAsIs() {
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

  /// 方向制御・ゼロ幅・改行・C1 制御を含む URL は、scheme が web でも開かない。
  func testLinkWithInvisibleCharactersIsBlocked() {
    for raw in [
      "https://example.com/\u{202E}txt.exe",
      "https://exa\u{200B}mple.com",
      "https://example.com/a\nb",
      "https://example.com/\u{85}",
      "vscode://file/\u{2028}etc",
    ] {
      XCTAssertEqual(decision(raw), .block(.unsafeCharacters), raw.debugDescription)
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

  // MARK: - file の実体

  /// 通常ファイルとディレクトリは、`..` と symlink を解決した実体の URL で開く（テキストはエディタ、フォルダは Finder）。
  func testOrdinaryFileAndDirectoryOpenAtResolvedLocation() throws {
    let file = try makeFile("notes.txt")
    let folder = dir.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let link = dir.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

    XCTAssertEqual(decision("file://\(folder.path)").allowedPath, canonical(folder).path)
    XCTAssertEqual(decision("file://\(link.path)").allowedPath, canonical(file).path)
    XCTAssertEqual(
      decision("file://\(folder.path)/../notes.txt").allowedPath, canonical(file).path)
  }

  /// 存在しないファイルと、通常ファイルでもディレクトリでもない実体（デバイス）は開かない。
  func testMissingOrSpecialFileIsBlocked() {
    XCTAssertEqual(
      decision("file://\(dir.appendingPathComponent("absent.txt").path)"),
      .block(.inaccessibleFile))
    XCTAssertEqual(decision("file:///dev/null"), .block(.inaccessibleFile))
  }

  /// テキストは実行ビット・スクリプトの型に関わらず GUI エディタで開く（実行しない）。
  func testTextFilesOpenInEditorRegardlessOfExecutableBit() throws {
    for target in [
      try makeFile("tool.txt", executable: true), try makeFile("setup.sh", executable: true),
      try makeFile("run.command"), try makeFile("app.py"),
    ] {
      XCTAssertEqual(
        decision("file://\(target.path)"), .allow(.text(canonical(target))),
        target.lastPathComponent)
    }
  }

  /// 別の場所を指す転送ファイルとアプリ・実行形式は開かない。
  func testForwardingAndExecutableFilesAreBlocked() throws {
    let webLocation = try makeFile("site.webloc")
    let appBundle = dir.appendingPathComponent("Fake.app", isDirectory: true)
    try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)

    for target in [webLocation, appBundle] {
      XCTAssertEqual(
        decision("file://\(target.path)"), .block(.unsafeFile), target.lastPathComponent)
    }
  }

  /// 無害そうな名前の symlink や `..` の綴りの裏にあるバイナリ実行ファイルも、実体で判定して開かない。
  func testExecutableBehindHarmlessSpellingIsBlocked() throws {
    let executable = try makeFile("tool", Data([0xCF, 0xFA, 0xED, 0xFE, 0x00]), executable: true)
    let disguise = dir.appendingPathComponent("readme.txt")
    try FileManager.default.createSymbolicLink(at: disguise, withDestinationURL: executable)
    let folder = dir.appendingPathComponent("folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    XCTAssertEqual(decision("file://\(disguise.path)"), .block(.unsafeFile))
    XCTAssertEqual(decision("file://\(folder.path)/../tool"), .block(.unsafeFile))
  }

  /// 拡張子の無い実行ビット付きファイルでも、中身がテキスト（シェルスクリプト等）ならエディタで開く。
  func testExecutableWithTextContentOpensInEditor() throws {
    let script = try makeFile("tool", Data("#!/bin/sh\necho hi\n".utf8), executable: true)
    XCTAssertEqual(decision("file://\(script.path)"), .allow(.text(canonical(script))))
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
    XCTAssertEqual(
      UntrustedLink("https://example.com/\u{202E}txt\u{200B}.exe").displayString,
      "https://example.com/\\u{202E}txt\\u{200B}.exe")
  }

  // MARK: - OSC 8 由来の識別

  /// libghostty が OSC 8 由来と伝えるリンクは、正規表現リンクと区別される（区別が消えると不信の判定を素通りする）。
  func testOSC8KindIsDistinguishedFromDetectedLinks() {
    XCTAssertEqual(OpenURL.Kind(GHOSTTY_ACTION_OPEN_URL_KIND_OSC8), .osc8)
    XCTAssertNotEqual(OpenURL.Kind(GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN), .osc8)
  }

  // MARK: - Helpers

  private func decision(_ raw: String) -> UntrustedLink.Decision {
    UntrustedLink(raw, localHosts: [Self.localHost]).decision
  }

  private func makeFile(
    _ name: String, _ data: Data = Data("content\n".utf8), executable: Bool = false
  ) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    return url
  }

  /// `..` と symlink を畳んだ実体（`/private` を剥がす Foundation の解決ではなく realpath(3) と同じ）。
  private func canonical(_ url: URL) -> URL {
    let resolved = realpath(url.path, nil)!
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
  }
}

extension UntrustedLink.Decision {
  fileprivate var allowedPath: String? {
    switch self {
    case .allow(.text(let url)), .allow(.folder(let url)): return url.path
    default: return nil
    }
  }
}
