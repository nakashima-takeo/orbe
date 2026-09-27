import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// IME が問う座標——文字の矩形・点の下の字・範囲の文字列は NSTextView と同じ約束で答え、変換中の未確定は描く行と揃い、
/// スクロールすれば候補窓が追従する。壊れると候補窓がずれる・未確定の中のクリックが 1 字ずれる。
extension SurfaceInputMethodTests {
  /// 変換中にスクロールすれば IME に文字の座標が変わったと知らせる（候補窓が追従する）。変換中でなければ、スクロール
  /// だけでは知らせない。
  func testScrollingWhileComposingMovesTheCandidateWindow() throws {
    let opened = try open((0..<200).map { "row \($0)" }.joined(separator: "\n"))
    _ = host(opened)
    let context = fakeInputMethod(opened)
    opened.surface.scroll(toTop: opened.document.text.lineStart(50), hiddenFraction: 0)
    XCTAssertEqual(context.invalidations, 0)
    replay([.mark("か")], on: opened)
    let composing = context.invalidations
    XCTAssertGreaterThan(composing, 0, "変換の変化でも知らせる")
    opened.surface.scroll(toTop: opened.document.text.lineStart(10), hiddenFraction: 0)
    XCTAssertGreaterThan(context.invalidations, composing)
  }

  /// 読む呼び出しは NSTextView と同じく、はみ出しを切り、範囲外は nil・NSNotFound を返す。
  func testQueriesClipAndAnswerNotFound() throws {
    let opened = try open("abc\ndef\n")
    let window = host(opened)
    let client = opened.surface.textView
    XCTAssertEqual(client.markedRange().location, NSNotFound)
    var actual = NSRange()
    XCTAssertEqual(
      client.attributedSubstring(
        forProposedRange: NSRange(location: 6, length: 10), actualRange: &actual)?
        .string, "f\n")
    XCTAssertEqual(actual, NSRange(location: 6, length: 2))
    XCTAssertNil(
      client.attributedSubstring(
        forProposedRange: NSRange(location: 8, length: 1), actualRange: nil))
    XCTAssertNil(
      client.attributedSubstring(
        forProposedRange: NSRange(location: 1, length: 0), actualRange: nil))
    let rect = client.firstRect(
      forCharacterRange: NSRange(location: 1, length: 5), actualRange: &actual)
    XCTAssertEqual(actual, NSRange(location: 1, length: 2), "1 行目の中身で切る")
    let local = client.convert(window.convertFromScreen(rect), from: nil)
    let config = opened.surface.config
    XCTAssertEqual(local.minY, config.topInset, accuracy: 0.5)
    XCTAssertEqual(local.height, config.lineHeight, accuracy: 0.5)
    XCTAssertEqual(local.width, 2 * config.cell, accuracy: 0.5)
    func screen(_ local: CGPoint) -> NSPoint {
      window.convertPoint(toScreen: client.convert(local, to: nil))
    }
    XCTAssertEqual(client.characterIndex(for: screen(point(opened, row: 1, column: 1))), 5)
    XCTAssertEqual(
      client.characterIndex(for: screen(point(opened, row: 1, column: 1.5))), 5,
      "字の右半分でも点を含む字（次の字ではない）")
    XCTAssertGreaterThan(
      client.fractionOfDistanceThroughGlyph(for: screen(point(opened, row: 1, column: 1.5))), 0.5,
      "割合は同じ字の中の位置")
    XCTAssertEqual(
      client.characterIndex(for: screen(point(opened, row: 1, column: 5))), NSNotFound, "行末より右")
    XCTAssertEqual(
      client.characterIndex(for: screen(point(opened, row: 2, column: 0))), NSNotFound, "字の無い行")
    XCTAssertEqual(
      client.characterIndex(for: screen(CGPoint(x: point(opened, row: 0, column: 1).x, y: 500))),
      NSNotFound, "本文の外")
  }

  /// 変換中の未確定の矩形と点の下の字は、描く行と同じ組版の位置で答える（未確定の先頭は変換の前の行から、中は未確定の
  /// 文字列から出しても、普通の字の並びでは描画と揃う）。
  func testMarkedRectsLineUpWithTheDrawnLine() throws {
    let opened = try open("let a = \n")
    let window = host(opened)
    fakeInputMethod(opened)
    let client = opened.surface.textView
    opened.surface.selectedRange = NSRange(location: 8, length: 0)
    replay([.mark("かなかな", selected: NSRange(location: 1, length: 2))], on: opened)
    let column = opened.surface.config.columnWidth(lineCount: 2)
    func local(_ range: NSRange) -> NSRect {
      client.convert(
        window.convertFromScreen(client.firstRect(forCharacterRange: range, actualRange: nil)),
        from: nil)
    }
    let marked = local(client.markedRange())
    XCTAssertEqual(marked.minX, column + caretX(opened, row: 0, offset: 8), accuracy: 0.5)
    XCTAssertEqual(marked.maxX, column + caretX(opened, row: 0, offset: 12), accuracy: 0.5)
    let selected = local(client.selectedRange())
    XCTAssertEqual(selected.minX, column + caretX(opened, row: 0, offset: 9), accuracy: 0.5)
    XCTAssertEqual(selected.maxX, column + caretX(opened, row: 0, offset: 11), accuracy: 0.5)
    let rightHalf = window.convertPoint(
      toScreen: client.convert(
        CGPoint(x: selected.minX + selected.width * 0.75 / 2, y: selected.midY), to: nil))
    XCTAssertEqual(client.characterIndex(for: rightHalf), 9, "未確定の字の右半分の点は、その字")
  }
}
