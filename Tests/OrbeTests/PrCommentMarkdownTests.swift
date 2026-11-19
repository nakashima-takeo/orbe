import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// コメントの本文の Markdown を絵の段へ変換する。壊れると、インラインコードの地や太字が付かない・リンクが押せない・箇条書きや
/// 引用の字下げが崩れる・描かない記法（表・HTML・suggestion）の字が欠ける・書いた字が別の字に化ける・深い入れ子の本文
/// 1 つでアプリが落ちる・本文のリンクから手元のアプリやファイルが開く。
@MainActor
final class PrCommentMarkdownTests: OrbeTestCase {
  /// 段落の中の見え方——インラインコードは余白つきの等幅、太字は太い字体、取り消し線とリンクは見え方の番号で記す。
  func testInlineStylesBecomeStylesOfOneParagraph() throws {
    let blocks = PrCommentMarkdown.blocks("**太字** と `code` と ~~消す~~ と [リンク](https://example.com/a)")
    XCTAssertEqual(blocks.count, 1)
    let block = try XCTUnwrap(blocks.first)
    XCTAssertEqual(block.text.string, "太字 と code と 消す と リンク")
    let styles = block.text.styles
    XCTAssertEqual(styles[0].font, Theme.Typography.editorPrThreadBodyStrong as CTFont)
    let code = try XCTUnwrap(styles.firstIndex { $0.leadingPadding > 0 })
    XCTAssertEqual(styles[code].font, Theme.Typography.editorPrThreadCode as CTFont)
    XCTAssertEqual(styles[code].length, 4)
    XCTAssertEqual(block.strikes.count, 1)
    XCTAssertEqual(block.links.values.first, URL(string: "https://example.com/a"))
  }

  /// 段の種類——コードブロックはコードの段、箇条書きは項目ごとに字下げと印、引用は線と字下げ、番号付きは開始の番号から。
  func testBlocksCarryIndentMarkersAndQuoteBars() {
    let blocks = PrCommentMarkdown.blocks(
      """
      - 一つ目
      - 二つ目

      3. 三
      4. 四

      > 引用

      ```swift
      let a = 1
      ```
      """)
    XCTAssertEqual(blocks.map { $0.markers.map(\.text) }, [["•"], ["•"], ["3."], ["4."], [], []])
    XCTAssertEqual(blocks[0].indent, Theme.Layout.editorPrBodyListIndent)
    XCTAssertEqual(blocks[4].quoteBars.map(\.x), [0])
    XCTAssertEqual(blocks[4].text.string, "引用")
    XCTAssertEqual(blocks[5].kind, .code)
    XCTAssertEqual(blocks[5].text.string, "let a = 1")
  }

  /// 描かない記法は、書かれた字のまま段落になる（表・HTML の段・suggestion のコードブロック）。字は 1 つも欠けない（日本語の
  /// 行の後でも）。
  func testUnsupportedSyntaxKeepsItsWrittenText() {
    let table = "| a | b |\n| - | - |\n| 1 | 2 |"
    XCTAssertEqual(PrCommentMarkdown.blocks(table).map(\.text.string), [table])
    XCTAssertEqual(
      PrCommentMarkdown.blocks("説明の段落\n\n" + table).map(\.text.string), ["説明の段落", table])
    let suggestion = "```suggestion\nlet b = 2\n```"
    XCTAssertEqual(PrCommentMarkdown.blocks(suggestion).map(\.text.string), [suggestion])
    XCTAssertEqual(
      PrCommentMarkdown.blocks("前 <b>太</b> 後").map(\.text.string), ["前 <b>太</b> 後"])
    XCTAssertEqual(
      PrCommentMarkdown.blocks("画像 ![図](https://example.com/a.png) の後").map(\.text.string),
      ["画像 ![図](https://example.com/a.png) の後"])
  }

  /// 書いた字は GitHub と同じく化けない（smart punctuation を付けない）。1 つの改行は改行のまま。
  func testWrittenPunctuationAndSingleLineBreaksStayAsWritten() {
    XCTAssertEqual(
      PrCommentMarkdown.blocks("a -- b --- c \"d\" 'e' ... git push --force").map(\.text.string),
      ["a -- b --- c \"d\" 'e' ... git push --force"])
    XCTAssertEqual(PrCommentMarkdown.blocks("一行目\n二行目").map(\.text.string), ["一行目\n二行目"])
  }

  /// 深く入れ子にした引用でも落ちず、字下げは上限の段で止まり、字は欠けない。
  func testDeeplyNestedQuotesDoNotCrashAndStopIndentingAtTheLimit() {
    let blocks = PrCommentMarkdown.blocks(String(repeating: ">", count: 20_000) + " 深い")
    XCTAssertEqual(blocks.map(\.text.string), ["深い"])
    XCTAssertEqual(blocks.first?.quoteBars.count, PrCommentMarkdown.maxDepth)
  }

  /// web とメールの行き先だけが押せるリンクになり、本文に直接書いた http(s) の URL もリンクになる（インラインコードの中は
  /// ならない）。
  func testOnlyWebAndMailDestinationsBecomeLinks() {
    XCTAssertTrue(
      PrCommentMarkdown.blocks("[計算機](file:///Applications/Calculator.app)")[0].links.isEmpty)
    XCTAssertTrue(PrCommentMarkdown.blocks("[x](myapp://open)")[0].links.isEmpty)
    let bare = PrCommentMarkdown.blocks("見て https://example.com/a. と `https://example.com/b`")[0]
    XCTAssertEqual(Array(bare.links.values), [URL(string: "https://example.com/a")!])
  }

  /// 引用・箇条書きの中の描かない記法も、書かれた字のまま（入れ物の前置きを外し、HTML と画像は書かれた字）。
  func testUnsupportedSyntaxInsideContainersKeepsItsWrittenText() {
    XCTAssertEqual(
      PrCommentMarkdown.blocks("> | a | b |\n> | - | - |\n> | 1 | 2 |").map(\.text.string),
      ["| a | b |\n| - | - |\n| 1 | 2 |"])
    XCTAssertEqual(
      PrCommentMarkdown.blocks("- 項目\n![図](https://example.com/a.png) 後").map(\.text.string),
      ["項目\n![図](https://example.com/a.png) 後"])
    XCTAssertEqual(
      PrCommentMarkdown.blocks("> 前\n<br> 後").map(\.text.string), ["前\n<br> 後"])
  }

  /// 同じ引用の段は同じ引用の番号の線を持ち、隣り合う別の引用は別の番号。
  func testQuoteBarsKnowWhichQuoteTheyBelongTo() {
    let one = PrCommentMarkdown.blocks("> 一\n>\n> 二")
    XCTAssertEqual(one.map(\.quoteBars), [one[0].quoteBars, one[0].quoteBars])
    let two = PrCommentMarkdown.blocks("> 一\n\n> 二")
    XCTAssertNotEqual(two[0].quoteBars, two[1].quoteBars)
  }

  /// 最初の子が箇条書きの項目は外側と内側の印を 1 行に並べ、項目の最初の子が引用でも印は項目の字下げの位置。10 以上の
  /// 番号は右揃えで、字下げは最も広い番号に合わせる。
  func testListMarkersStayAtTheirItemsAndNumbersAlignRight() {
    let nested = PrCommentMarkdown.blocks("- - a\n- b")
    XCTAssertEqual(nested[0].markers.map(\.text), ["•", "•"])
    XCTAssertEqual(nested[0].markers.map(\.x), [0, Theme.Layout.editorPrBodyListIndent])
    XCTAssertEqual(PrCommentMarkdown.blocks("- > 引用\n- b").map { $0.markers.map(\.x) }, [[0], [0]])
    let numbered = PrCommentMarkdown.blocks("9. 九\n10. 十")
    let rights = numbered.map { block in
      block.markers[0].x
        + ZoneTextLayout.width([
          ZoneTextRun(
            block.markers[0].text, font: Theme.Typography.editorPrThreadBody, color: .clear)
        ])
    }
    XCTAssertEqual(rights[0], rights[1], accuracy: 0.01)
    XCTAssertEqual(numbered[0].indent, numbered[1].indent)
    XCTAssertGreaterThanOrEqual(
      numbered[0].indent - rights[0], Theme.Layout.editorPrBodyListMarkerGap - 0.01)
  }
}
