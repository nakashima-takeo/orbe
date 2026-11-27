import Foundation
import XCTest

@testable import Orbe

/// ブラウザ URL 欄の入力正規化（スキーム省略補完・非 HTTP(S) 拒否・裸語拒否）と
/// 2 トーン表示用の分解規則（ホスト・ポート・パス・HTTPS 鍵・空ページ除外）を守る。
///
/// 壊れると何が起きるか。ローカル開発サーバー（`localhost:5173` 等）へ HTTPS 誤補完で繋がらなくなる、
/// あるいは `javascript:` / `file:` のような危険スキームが誤って遷移してしまう。
/// 表示分解が壊れると HTTPS 鍵アイコンやホスト部・パス部の 2 トーン表示が崩れる。
final class BrowserURLInputTests: OrbeTestCase {
  /// `isValidHTTPNavigationURL` は HTTP(S) スキームかつ非空ホスト（大文字スキーム・IPv6 含む）のみ許可し、
  /// `nil`・空ホスト・非 HTTP(S) スキーム群を拒否する。
  func testIsValidHTTPNavigationURLAcceptsHTTPWithHostAndRejectsOthers() {
    let valid = [
      "http://localhost",
      "https://example.com/path?q=1#top",
      "HTTP://Example.COM:8080/",
      "HTTPS://[::1]:3000/app",
      "http://127.0.0.1/",
    ]
    for raw in valid {
      XCTAssertTrue(
        BrowserURLInput.isValidHTTPNavigationURL(URL(string: raw)),
        "許可すべき URL が拒否された: \(raw)")
    }

    XCTAssertFalse(BrowserURLInput.isValidHTTPNavigationURL(nil))
    let rejected = [
      "http:///only-path",
      "https://",
      "about:blank",
      "file:///etc/passwd",
      "javascript:alert(1)",
      "data:text/html,<h1>x</h1>",
      "ftp://example.com",
      "mailto:user@example.com",
      "orbe://open",
    ]
    for raw in rejected {
      XCTAssertFalse(
        BrowserURLInput.isValidHTTPNavigationURL(URL(string: raw)),
        "拒否すべき URL が許可された: \(raw)")
    }
  }

  /// 明示 HTTP(S) を維持し、スキーム省略時はローカル開発向けへ `http://`、通常ホストへ `https://` を補完する。
  func testResolveNormalizesHTTPURLsAndInfersLocalVsPublicScheme() {
    let cases: [(input: String, expected: String)] = [
      ("  https://example.com/a?x=1#h  ", "https://example.com/a?x=1#h"),
      ("HTTP://Example.COM/Path", "HTTP://Example.COM/Path"),
      ("localhost", "http://localhost"),
      ("localhost:5173/api", "http://localhost:5173/api"),
      ("127.0.0.1:8080/health", "http://127.0.0.1:8080/health"),
      ("192.168.1.10", "http://192.168.1.10"),
      ("[::1]:3000/app", "http://[::1]:3000/app"),
      ("dev.local/status", "http://dev.local/status"),
      ("example.com:8080", "http://example.com:8080"),
      ("example.com/docs?q=1#top", "https://example.com/docs?q=1#top"),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(BrowserURLInput.resolve(input)?.absoluteString, expected, "入力: \(input)")
    }
  }

  /// 空・空白を含む語句・裸語・非 HTTP(S) スキーム・不正なホストやポートは遷移させず nil で弾く。
  func testResolveRejectsNonHTTPSchemesMalformedAndPlainWords() {
    let rejected = [
      "",
      "   \n\t ",
      "hello world",
      "orbe",
      "file:///etc/passwd",
      "javascript:alert(1)",
      "data:text/html,<h1>x</h1>",
      "ftp://example.com",
      "mailto:user@example.com",
      "http://",
      "https://",
      "example.com:0",
      "example.com:65536",
      "127.0.0.1:99999",
      "foo..bar",
      ".example.com",
      "example.com.",
      "[::1",
      "[::1]:0",
    ]
    for input in rejected {
      XCTAssertNil(BrowserURLInput.resolve(input), "拒否すべき入力が受理された: \(input)")
    }
  }

  /// URL をホスト部とパス部へ分解し、`about:blank` 等の空ページは nil としてプレースホルダへ落とす。
  func testDisplaySplitsHostAndPathAndOmitsBlankPages() {
    XCTAssertNil(BrowserURLInput.display(nil))
    XCTAssertNil(BrowserURLInput.display(URL(string: "about:blank")))

    let root = BrowserURLInput.display(URL(string: "https://docs.orbe.dev/"))
    XCTAssertEqual(
      root,
      BrowserDisplayURL(
        host: "docs.orbe.dev", path: "", isSecure: true, raw: "https://docs.orbe.dev/"))

    let local = BrowserURLInput.display(URL(string: "http://localhost:5173/api?k=v#top"))
    XCTAssertEqual(
      local,
      BrowserDisplayURL(
        host: "localhost:5173", path: "/api?k=v#top", isSecure: false,
        raw: "http://localhost:5173/api?k=v#top"))

    let ipv6WithPort = BrowserURLInput.display(URL(string: "http://[::1]:3000/app"))
    XCTAssertEqual(
      ipv6WithPort,
      BrowserDisplayURL(
        host: "[::1]:3000", path: "/app", isSecure: false, raw: "http://[::1]:3000/app"))

    let ipv6NoPort = BrowserURLInput.display(URL(string: "http://[::1]/"))
    XCTAssertEqual(
      ipv6NoPort,
      BrowserDisplayURL(host: "[::1]", path: "", isSecure: false, raw: "http://[::1]/"))
  }

  /// 日本語等の可読 UTF-8 パスは維持しつつ、表示反転・切り詰めを起こす Bidi 書式文字・制御文字・
  /// 行/段落区切りを UTF-8 バイト単位で再パーセントエンコードする。
  func testDisplayReEncodesBidiControlsAndLineSeparatorsWhileKeepingReadableUTF8() throws {
    let readable = try XCTUnwrap(
      BrowserURLInput.display(
        URL(string: "https://ja.wikipedia.org/wiki/%E6%9D%B1%E4%BA%AC"), isSecure: true))
    XCTAssertEqual(readable.host, "ja.wikipedia.org")
    XCTAssertEqual(readable.path, "/wiki/東京")
    XCTAssertTrue(readable.isSecure)

    // Bidi 書式文字（RLM・LRM・RLO・ALM・LRI/RLI/FSI/PDI）を再パーセントエンコードする。
    let bidiCases: [(encoded: String, label: String)] = [
      ("%E2%80%8F", "RLM (U+200F)"),
      ("%E2%80%8E", "LRM (U+200E)"),
      ("%E2%80%AE", "RLO (U+202E)"),
      ("%D8%9C", "ALM (U+061C)"),
      ("%E2%81%A6", "LRI (U+2066)"),
      ("%E2%81%A7", "RLI (U+2067)"),
      ("%E2%81%A8", "FSI (U+2068)"),
      ("%E2%81%A9", "PDI (U+2069)"),
    ]
    for (encoded, label) in bidiCases {
      let url = try XCTUnwrap(URL(string: "https://192.0.2.1/a\(encoded)b"))
      let displayed = try XCTUnwrap(BrowserURLInput.display(url, isSecure: true))
      XCTAssertEqual(displayed.host, "192.0.2.1", label)
      XCTAssertEqual(displayed.path, "/a\(encoded)b", "\(label) は再パーセントエンコードされる")
    }

    // 制御文字（NUL・LF・DEL・C1 制御文字）および行/段落区切り（U+2028・U+2029）を再エンコードする。
    let controlCases: [(encoded: String, label: String)] = [
      ("%00", "NUL (U+0000)"),
      ("%0A", "LF (U+000A)"),
      ("%7F", "DEL (U+007F)"),
      ("%C2%85", "NEL C1 (U+0085)"),
      ("%C2%9F", "APC C1 (U+009F)"),
      ("%E2%80%A8", "Line Separator (U+2028)"),
      ("%E2%80%A9", "Paragraph Separator (U+2029)"),
    ]
    for (encoded, label) in controlCases {
      let url = try XCTUnwrap(URL(string: "https://example.com/p\(encoded)q"))
      let displayed = try XCTUnwrap(BrowserURLInput.display(url, isSecure: false))
      XCTAssertEqual(displayed.path, "/p\(encoded)q", "\(label) は再パーセントエンコードされる")
      XCTAssertFalse(displayed.isSecure)
    }

    // 生の危険文字を含む文字列（パス・クエリ・フラグメント混在）でも可読部を残し危険文字だけ再エンコードする。
    let mixed = try XCTUnwrap(
      URL(string: "https://example.com/wiki/%E6%9D%B1%E4%BA%AC%E2%80%AE%0A?q=1#top"))
    let mixedDisplay = try XCTUnwrap(BrowserURLInput.display(mixed, isSecure: true))
    XCTAssertEqual(mixedDisplay.path, "/wiki/東京%E2%80%AE%0A?q=1#top")

    // ホスト部にパーセントエンコード済みの Bidi 書式文字・制御文字を含む場合も再エンコードする。
    let hostCases: [(url: String, expectedHost: String)] = [
      ("https://ex%E2%80%AEample.com:8080/a", "ex%E2%80%AEample.com:8080"),
      ("https://ex%0Aample.com/a", "ex%0Aample.com"),
    ]
    for (rawURL, expectedHost) in hostCases {
      let displayed = try XCTUnwrap(BrowserURLInput.display(URL(string: rawURL), isSecure: true))
      XCTAssertEqual(displayed.host, expectedHost, "\(rawURL) のホスト危険文字は再エンコードされる")
      XCTAssertEqual(displayed.path, "/a")
    }
  }
}
