import SwiftUI
import XCTest

@testable import Orbe

/// `BrowserTabDisplay` のタイトル・ホスト表示サニタイズ（Bidi 書式文字・制御文字・行/段落区切り）、
/// 空タイトル時のホスト／フォールバック解決、モノグラム・ローカルバッジ文字抽出、および
/// FNV-1a 決定論チップ配色を守る。
///
/// 壊れると何が起きるか。悪意ある Web ページの `<title>` やパーセントエンコード済みホストで
/// サイドバー・Favorites・新タブ画面・ツールチップに表示反転や複数行化・モノグラム空白化が起きる。
/// あるいは空タイトル時にホストへフォールバックせず識別不能になる、またはプロセス再起動ごとに
/// タブチップの色が変わって視覚的な手掛かりが失われる。
final class BrowserTabDisplayTests: OrbeTestCase {
  /// Bidi 書式文字・その他制御文字を除去し、改行・タブ・行/段落区切りを半角スペースへ畳んでトリムする。
  func testSanitizeTitleRemovesBidiAndControlsAndFoldsLineSeparators() {
    let raw =
      "  \u{202E}Evil\u{200F}\tTitle\nLine2\rLine3\u{2028}Sep\u{2029}Para\u{0000}\u{0085}\u{009F}  "
    XCTAssertEqual(BrowserTabDisplay.sanitizeTitle(raw), "Evil Title Line2 Line3 Sep Para")

    let bidiOnly = "\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{061C}\u{0000}\u{007F}\t\n"
    XCTAssertEqual(BrowserTabDisplay.sanitizeTitle(bidiOnly), "")
  }

  /// `title` と `shortLabel` はサニタイズ済みタイトルを優先し、空ならホスト（`shortLabel` は `www.` 除去）、
  /// それも無ければフォールバックへ降り、危険ホストも再パーセントエンコードで無害化する。
  func testTitleAndShortLabelFallbackAndSanitizeHosts() throws {
    let url = try XCTUnwrap(URL(string: "https://www.Example.COM/docs"))
    XCTAssertEqual(
      BrowserTabDisplay.title(url: url, title: " \u{202E}Docs\u{2028}Guide ", fallback: "New Tab"),
      "Docs Guide")
    XCTAssertEqual(
      BrowserTabDisplay.title(url: url, title: "\u{202E}\t ", fallback: "New Tab"),
      "www.Example.COM")
    XCTAssertEqual(
      BrowserTabDisplay.shortLabel(url: url, title: "  ", fallback: "New Tab"),
      "example.com")

    let wwwOnly = try XCTUnwrap(URL(string: "https://www./"))
    XCTAssertEqual(
      BrowserTabDisplay.shortLabel(url: wwwOnly, title: "", fallback: "New Tab"),
      "www.", "4 文字の www. 自体は空文字へ落とさない")

    XCTAssertEqual(
      BrowserTabDisplay.title(url: nil, title: "\u{0000}", fallback: "New Tab"), "New Tab")
    XCTAssertEqual(
      BrowserTabDisplay.shortLabel(url: nil, title: "", fallback: "New Tab"), "New Tab")

    let evilHost = try XCTUnwrap(URL(string: "https://ex%E2%80%AEample.com/a"))
    XCTAssertEqual(
      BrowserTabDisplay.title(url: evilHost, title: "", fallback: "New Tab"),
      "ex%E2%80%AEample.com")
    XCTAssertEqual(
      BrowserTabDisplay.shortLabel(url: evilHost, title: "", fallback: "New Tab"),
      "ex%E2%80%AEample.com")
  }

  /// `monogram` と `localBadgeLetter` は不可視制御文字をスキップして最初の可視文字を大文字化し、
  /// `monogram` はホスト優先・空で `nil`、`localBadgeLetter` は空で `"O"` を返す。
  func testMonogramAndLocalBadgeLetterSkipControlCharactersAndFallback() throws {
    let wwwURL = try XCTUnwrap(URL(string: "https://www.github.com/orbe"))
    XCTAssertEqual(BrowserTabDisplay.monogram(url: wwwURL, title: "Home"), "G")
    XCTAssertEqual(
      BrowserTabDisplay.monogram(url: nil, title: "\u{202E}\u{0000} alpha"), "A",
      "不可視文字が先頭でも空白モノグラムにならず可視文字を取る")
    XCTAssertNil(BrowserTabDisplay.monogram(url: nil, title: "\u{202E}\t "))

    let evilHost = try XCTUnwrap(URL(string: "https://%E2%80%AEbank.example/"))
    XCTAssertEqual(
      BrowserTabDisplay.monogram(url: evilHost, title: ""), "%",
      "先頭 Bidi 制御文字ホストは再エンコードされ不可視モノグラムにならない")

    XCTAssertEqual(BrowserTabDisplay.localBadgeLetter(workspaceName: "\u{202E}  orbe"), "O")
    XCTAssertEqual(BrowserTabDisplay.localBadgeLetter(workspaceName: "frontend"), "F")
    XCTAssertEqual(BrowserTabDisplay.localBadgeLetter(workspaceName: "\u{202E}\n\t"), "O")
  }

  /// `chipTint` は同一ホスト（大文字小文字・`www.` の揺れ吸収）で決定論的に同一色を返し、
  /// 空入力では `nil`、異なるホスト群で複数色に分散する。
  func testChipTintIsDeterministicNormalizesHostAndDistributesColors() throws {
    XCTAssertNil(BrowserTabDisplay.chipTint(url: nil, title: ""))
    XCTAssertNil(BrowserTabDisplay.chipTint(url: nil, title: "\u{202E}\t "))

    let a = try XCTUnwrap(URL(string: "https://www.Example.COM/page1"))
    let b = try XCTUnwrap(URL(string: "http://example.com/page2"))
    XCTAssertEqual(
      BrowserTabDisplay.chipTint(url: a, title: "A"),
      BrowserTabDisplay.chipTint(url: b, title: "B"),
      "大文字小文字と www. 接頭辞・パス差を吸収して同一色になる")

    let hosts = [
      "https://alpha.example", "https://beta.example", "https://gamma.example",
      "https://delta.example", "https://epsilon.example", "https://zeta.example",
      "https://eta.example", "https://theta.example", "https://iota.example",
      "https://kappa.example", "https://lambda.example", "https://mu.example",
    ]
    let distinctNonNil = Set(
      hosts.compactMap { raw -> String? in
        guard let color = BrowserTabDisplay.chipTint(url: URL(string: raw), title: "") else {
          return nil
        }
        return String(describing: color)
      })
    XCTAssertGreaterThanOrEqual(distinctNonNil.count, 3, "複数ホストで FNV-1a 配色が分散する")
  }
}
