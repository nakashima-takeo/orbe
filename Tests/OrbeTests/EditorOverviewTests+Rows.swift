import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// ミニマップの行の縮図——字を矩形に置き換えた形（インデントぶん右へ・字数に比例した幅・上限・空白だけの行は
/// 無い）、コメント行の色（tree-sitter の役割で決まる）、本文の編集と文書の切替への追従。
///
/// 壊れると何が起きるか。縮図が本文の形と合わず、ミニマップから「どのあたりか」を辿れない。打鍵しても縮図が古い
/// 本文のままで、行を足すと後ろの縮図が 1 行ずれたまま残る。文書を切り替えても前の文書の縮図が出続ける。
extension EditorOverviewTests {
  /// 帯（α .07）の上の行（α .15）と、帯だけの画素を分ける濃さ。
  private var rowInk: Int { 40 }
  /// 帯だけ（α .07 ≈ 18）か地の画素と、帯の外の行（α .15 ≈ 38）を分ける濃さ。
  private var bandInk: Int { 28 }
  /// 帯の上のコメント行（α .40 ≈ 112）と素の行（≈ 53）を分ける濃さ。
  private var commentInk: Int { 85 }

  func testRowsShiftByTheirIndentAndGrowWithTheirLengthUpToTheCap() throws {
    let text = [
      String(repeating: "a", count: 20),
      "    " + String(repeating: "b", count: 20),
      "        ",
      String(repeating: "c", count: 200),
    ].joined(separator: "\n")
    let view = try host(text + "\n").pane.overview

    XCTAssertTrue(try alpha(view, rowX(view, 3), rowY(0)) > rowInk, "行 1 は左余白から")
    XCTAssertTrue(try alpha(view, rowX(view, 14), rowY(0)) < rowInk, "20 字は 11 で終わる")

    XCTAssertTrue(try alpha(view, rowX(view, 3), rowY(1)) < rowInk, "インデント 4 桁ぶん（4.4）右へ")
    XCTAssertTrue(try alpha(view, rowX(view, 7.5), rowY(1)) > rowInk)
    XCTAssertTrue(try alpha(view, rowX(view, 13), rowY(1)) > rowInk, "幅は字数のまま（右へずれるだけ）")

    XCTAssertTrue(try alpha(view, rowX(view, 3), rowY(2)) < rowInk, "空白だけの行は描かない")
    XCTAssertTrue(try alpha(view, rowX(view, 12), rowY(2)) < rowInk)

    XCTAssertTrue(try alpha(view, rowX(view, 69), rowY(3)) > rowInk, "長い行は上限 72 まで")
    XCTAssertTrue(try alpha(view, rowX(view, 75), rowY(3)) < rowInk, "上限の先には伸びない")
  }

  /// コメント行は構文の役割で決まる——接頭辞の無いブロックコメントの中の行はコメント、文字列の中の `//` で始まる
  /// 行と、コードの後ろにコメントが付く行は違う。
  func testCommentRowsAreDecidedBySyntaxRolesNotByLinePrefixes() throws {
    let text = """
      let value = 1 // a trailing comment
      // a line comment that is long
      /* a block comment starts here
         inside the block, no prefix
      */
      let text = \"\"\"
      // inside a string, not a comment
      \"\"\"

      """
    let view = try host(text, name: "c-\(UUID().uuidString).swift", colored: true).pane.overview

    XCTAssertTrue(try alpha(view, rowX(view, 4), rowY(1)) > commentInk, "行コメント")
    XCTAssertTrue(try alpha(view, rowX(view, 4), rowY(2)) > commentInk, "ブロックコメントの先頭")
    XCTAssertTrue(try alpha(view, rowX(view, 8), rowY(3)) > commentInk, "ブロックの中（接頭辞なし）")
    for (line, what) in [(0, "後ろにコメントが付くコード"), (5, "コード"), (6, "文字列の中の //")] {
      let ink = try alpha(view, rowX(view, 4), rowY(line))
      XCTAssertTrue(ink > rowInk && ink < commentInk, "\(what)は素の行の色: \(ink)")
    }
  }

  /// 文法の無い文書は `//` で始まる行も素の色（接頭辞で見ていない）。
  func testADocumentWithoutAGrammarHasNoCommentRows() throws {
    let view = try host("// looks like a comment line\nplain text goes here\n").pane.overview
    let ink = try alpha(view, rowX(view, 4), rowY(0))
    XCTAssertTrue(ink > rowInk && ink < commentInk, "\(ink)")
  }

  /// 描いた後の打鍵で縮図が追従する。行が増えれば、編集より後ろの縮図も 1 行ずれる（覚えた縮図を出し続けない）。
  func testRowsFollowTypingAndShiftWhenALineIsInserted() throws {
    var source = (1...300).map { "line \($0) has text" }
    source[100] = ""
    let hosted = try host(source.joined(separator: "\n") + "\n", height: 800)
    let view = hosted.pane.overview
    let surface = hosted.document.surface
    XCTAssertTrue(try alpha(view, rowX(view, 3), rowY(99)) > 0)
    XCTAssertEqual(try alpha(view, rowX(view, 3), rowY(100)), 0, "空行は縮図が無い（帯の外なので地）")

    hosted.window.makeFirstResponder(surface.responder)
    surface.selectedRange = NSRange(location: 0, length: 0)
    surface.responder.keyDown(with: .key("\n", []))
    XCTAssertTrue(try alpha(view, rowX(view, 3), rowY(100)) > 0, "元の行 100 が 1 行下がって来る")
    XCTAssertEqual(try alpha(view, rowX(view, 3), rowY(101)), 0, "空行も 1 行下がる")

    surface.selectedRange = NSRange(
      location: hosted.document.lineIndex.start(ofRow: 101), length: 0)
    for _ in 0..<10 { surface.responder.keyDown(with: .key("x", [])) }
    XCTAssertTrue(try alpha(view, rowX(view, 3), rowY(101)) > 0, "打った行に縮図が出る")
  }

  /// 俯瞰は焦点の文書に結ばれる。切り替えれば新しい文書の縮図になり、戻れば戻る。
  func testSwitchingDocumentsRebindsTheOverview() throws {
    let first = (1...100).map { "line \($0) of the first document\n" }.joined()
    let hosted = try host(first)
    let view = hosted.pane.overview
    XCTAssertTrue(try alpha(view, rowX(view, 4), rowY(0)) > rowInk)
    XCTAssertTrue(try alpha(view, rowX(view, 4), rowY(50)) > 0)

    let other = try hosted.tab.editor.open(
      try caseFile("short.txt", "\nthe second line of a short document\n"))
    XCTAssertEqual(try alpha(view, rowX(view, 4), rowY(50)), 0, "前の文書の行は残らない")
    XCTAssertTrue(
      try alpha(view, rowX(view, 4), rowY(0)) < bandInk, "新しい文書の 1 行目は空（前の文書の縮図を出さない）")
    XCTAssertTrue(try alpha(view, rowX(view, 4), rowY(1)) > 0, "新しい文書の 2 行目")

    hosted.tab.editor.close(other)
    XCTAssertTrue(try alpha(view, rowX(view, 4), rowY(50)) > 0, "戻れば元の文書")
  }
}
