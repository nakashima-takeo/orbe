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
}
