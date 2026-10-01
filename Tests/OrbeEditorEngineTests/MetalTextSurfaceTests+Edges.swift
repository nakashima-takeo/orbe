import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 面の端の場面——空の文書、End キーの最後の 1 画面、役割だけが変わった行の描き直し、行の桁が増えた打鍵での行番号の
/// 列の広がり。壊れると、空の文書で行番号も構文の見えている範囲も無い、End で最終行が下端に来ない、裏から届いた色が
/// 見えている行に出ない、10 行目を作った打鍵で行番号が本文に重なる。
extension MetalTextSurfaceTests {
  /// 空の文書にも見えている範囲（先頭・行 1 つ以上）と行番号「1」がある。スクロールした後に全部消しても先頭へ戻る。
  func testAnEmptyDocumentHasAViewportAndLineOne() throws {
    let empty = try open("", name: "a.txt")
    XCTAssertEqual(empty.surface.viewport.firstVisible, 0)
    XCTAssertGreaterThan(empty.surface.viewport.visibleLines, 0)
    let config = empty.surface.config
    let shot = try pixelShot(empty)
    let y = config.topInset + config.lineHeight / 2
    XCTAssertTrue(
      stride(from: CGFloat(1), to: config.gutterWidth, by: 0.5).contains { shot.hasInk($0, y) },
      "行番号の 1 が描かれる")

    let opened = try open((0..<100).map { "row \($0)" }.joined(separator: "\n"), name: "b.txt")
    opened.surface.scroll(toFirstLine: 50)
    opened.surface.replaceAll(with: "")
    XCTAssertEqual(opened.surface.viewport.firstVisible, 0, "消せば先頭")
    XCTAssertEqual(opened.surface.scrollPosition.y, 0)
  }

  /// End（`scrollToEndOfDocument`）は最後の 1 画面——最終行（末尾の空行）が下端に来る。キャレットは動かない。
  func testEndKeyShowsTheLastScreen() throws {
    let opened = try open((0..<100).map { "row \($0)" }.joined(separator: "\n") + "\n")
    _ = host(opened)
    opened.surface.textView.scrollToEndOfDocument(nil)
    let (first, visible) = opened.surface.viewportLines
    XCTAssertEqual(first + visible, CGFloat(opened.document.text.lineCount), accuracy: 0.01)
    XCTAssertEqual(opened.surface.caretLocation, 0)
  }

  /// 本文の変わっていない行の役割だけが裏から変わっても（離れた閉じの手前で開いたブロックコメント）、見えている行を
  /// 新しい色で描き直す——開き直したのと同じ絵。
  func testRowsWhoseRolesAloneChangeAreRedrawn() throws {
    var lines = (0..<30).map { "let value\($0) = \($0)" }
    lines[20] = "// */"
    let opened = try open(
      lines.joined(separator: "\n") + "\n", size: CGSize(width: 400, height: 300))
    _ = try pixelShot(opened)
    opened.surface.selectedRange = NSRange(location: opened.document.text.lineStart(2), length: 0)
    opened.surface.perform(.insert("/*"))
    _ = try pixelShot(opened)
    XCTAssertTrue(opened.document.waitUntilCaughtUp())
    let untouched = NSRange(location: opened.document.text.lineStart(5), length: 3)
    XCTAssertEqual(
      opened.document.roles.roles(in: untouched).map(\.role), [.comment],
      "前提: 本文の変わらない行がコメントの役割になった")
    opened.surface.selectedRange = NSRange(location: 0, length: 0)
    var edited = lines
    edited[2] = "/*" + edited[2]
    let fresh = try open(
      edited.joined(separator: "\n") + "\n", size: CGSize(width: 400, height: 300))
    XCTAssertTrue(try pixelShot(opened).bytes == (try pixelShot(fresh)).bytes, "開き直したのと同じ絵")
  }

  /// 行の桁が増える打鍵（9…9 行目の後に改行）は、その打鍵の取引で行番号の列を広げ、本文の区画を右へずらす。
  func testTheNumberColumnWidensWithTheKeystrokeThatAddsADigit() throws {
    let config = SurfaceConfig(style: Self.style(), omittedLabel: { "\($0)" })
    let digits = try XCTUnwrap(
      (1...7).first {
        config.columnWidth(lineCount: Int(pow(10, Double($0))))
          > config
          .columnWidth(lineCount: Int(pow(10, Double($0))) - 1)
      }, "前提: いずれかの桁で列が広がる")
    let count = Int(pow(10, Double(digits)))
    let opened = try open(
      String(repeating: "x\n", count: count - 2) + "x", name: "a.txt", waitForColors: false)
    XCTAssertEqual(opened.document.text.lineCount, count - 1)
    let narrow = opened.surface.surfaceLayout
    opened.surface.selectedRange = NSRange(location: opened.document.text.length, length: 0)
    opened.surface.perform(.newline(indents: false))
    let wide = opened.surface.surfaceLayout
    XCTAssertEqual(wide.column, config.columnWidth(lineCount: count))
    XCTAssertGreaterThan(wide.column, narrow.column)
    XCTAssertEqual(wide.text.minX, wide.column, "本文の区画は列の右から")
    XCTAssertEqual(opened.surface.drawn.content?.text.lineCount, count, "同じ取引で出す")
  }
}
