import XCTest

@testable import Orbe

/// SurfaceView.escapeShellPath（ファイル/フォルダ D&D で挿入するパスのシェルエスケープ）の検証。
/// 実 Finder ドラッグの受理（draggingEntered/performDragOperation）は実機確認が要るため対象外。
/// ここではパス組み立ての pure function のみ検証する。
final class DragDropPathEscapeTests: XCTestCase {

  func testNoSpecialCharactersUnchanged() {
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/Users/me/file.txt"), "/Users/me/file.txt",
      "特殊文字なしはそのまま")
  }

  func testEscapesSpace() {
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/Users/me/My Documents/a.txt"),
      "/Users/me/My\\ Documents/a.txt", "スペースはバックスラッシュエスケープ")
  }

  func testEscapesVariousSpecialCharacters() {
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/tmp/a(b)[c]{d}.txt"),
      "/tmp/a\\(b\\)\\[c\\]\\{d\\}.txt", "括弧類をエスケープ")
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/tmp/a&b;c|d.txt"),
      "/tmp/a\\&b\\;c\\|d.txt", "シェル制御文字をエスケープ")
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/tmp/a'b\"c`d.txt"),
      "/tmp/a\\'b\\\"c\\`d.txt", "クォート類をエスケープ")
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/tmp/a$b!c#d.txt"),
      "/tmp/a\\$b\\!c\\#d.txt", "展開・履歴・コメント記号をエスケープ")
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/tmp/a<b>c*d?e.txt"),
      "/tmp/a\\<b\\>c\\*d\\?e.txt", "リダイレクト・グロブ記号をエスケープ")
  }

  // MARK: - 制御文字の除去
  //
  // 挿入先は pty へ生バイトを書くため、制御文字はバックスラッシュを前置しても中和されない。
  // 改行を含む名前のファイルは APFS 上で作成でき、zsh は `^J` を accept-line と解釈するので、
  // 除去しないと「ドロップしただけで Enter を押していないのにコマンドが走る」経路になる。

  func testRemovesNewline() {
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/tmp/photo.jpg\nreboot\n"), "/tmp/photo.jpgreboot",
      "改行は除去する（エスケープでは行が確定してしまう）")
  }

  func testRemovesCarriageReturnAndCRLF() {
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/tmp/a\rb.txt"), "/tmp/ab.txt", "復帰も除去する")
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/tmp/a\r\nb.txt"), "/tmp/ab.txt", "CRLF も除去する")
  }

  func testRemovesTabAndOtherControlCharacters() {
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/tmp/a\tb.txt"), "/tmp/ab.txt",
      "タブは除去する（ZLE が補完起動として食うためエスケープが効かない）")
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/tmp/a\u{01}b\u{1B}c.txt"), "/tmp/abc.txt",
      "その他の制御文字も除去する")
  }

  func testEscapesBackslashItself() {
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/tmp/a\\b.txt"), "/tmp/a\\\\b.txt", "バックスラッシュ自体もエスケープ")
  }

  func testFolderPathHasNoTrailingSlashHandling() {
    // URL.path はディレクトリでも末尾 / を付与しないため、ファイルと同じ扱いで通る。
    XCTAssertEqual(
      SurfaceView.escapeShellPath("/Users/me/My Folder"), "/Users/me/My\\ Folder",
      "フォルダパスもファイルと同じくスペースをエスケープ")
  }

  func testEmptyPathReturnsEmpty() {
    XCTAssertEqual(SurfaceView.escapeShellPath(""), "", "空文字はそのまま")
  }

  // MARK: - 複数パスのスペース結合（completion 4 → performDragOperation と同じ組み立て）

  func testJoinsMultiplePathsWithSpace() {
    let urls = ["/Users/me/a.txt", "/Users/me/b dir/c.txt", "/tmp/d.txt"]
    let joined = urls.map { SurfaceView.escapeShellPath($0) }.joined(separator: " ")
    XCTAssertEqual(
      joined, "/Users/me/a.txt /Users/me/b\\ dir/c.txt /tmp/d.txt",
      "各パスをエスケープした上でスペース区切りで結合")
  }

  func testSinglePathHasNoTrailingSeparator() {
    let urls = ["/Users/me/a.txt"]
    let joined = urls.map { SurfaceView.escapeShellPath($0) }.joined(separator: " ")
    XCTAssertEqual(joined, "/Users/me/a.txt", "単一パスは区切り文字なし")
  }
}
