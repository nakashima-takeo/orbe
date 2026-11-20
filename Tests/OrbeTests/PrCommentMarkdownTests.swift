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
      PrCommentMarkdown.blocks("| a | b |\r\n| - | - |\r\n| 1 | 2 |").map(\.text.string), [table],
      "CRLF の表も同じ字")
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
    XCTAssertEqual(
      Array(PrCommentMarkdown.blocks("[連絡](mailto:a@example.com)")[0].links.values),
      [URL(string: "mailto:a@example.com")!])
    XCTAssertTrue(
      PrCommentMarkdown.blocks("見て https://example.com/\u{202E}a")[0].links.isEmpty,
      "本文に直接書いた URL も明示のリンクと同じ判定で、危ない字を含めば押せない")
  }

  /// タスクの記法は書かれた字のまま（大文字の X も、同じ行の後ろに [x] があっても、中身の無いタスクも）。
  func testTaskItemsKeepTheirWrittenText() {
    XCTAssertEqual(
      PrCommentMarkdown.blocks("- [ ] 未\n- [X] 済\n- [ ] 後で [x] と書く\n- [ ]").map(\.text.string),
      ["[ ] 未", "[X] 済", "[ ] 後で [x] と書く", "[ ]"])
  }

  /// 入れ子の上限より深い箇条書きの項目でも、印は項目の字に重ならない。
  func testAListDeeperThanTheLimitKeepsItsMarkerOffTheText() throws {
    let source = (0...PrCommentMarkdown.maxDepth).map {
      String(repeating: "  ", count: $0) + "- 段\($0)"
    }.joined(separator: "\n")
    let deepest = try XCTUnwrap(PrCommentMarkdown.blocks(source).last)
    let marker = try XCTUnwrap(deepest.markers.last)
    let width = NSAttributedString(
      string: marker.text, attributes: [.font: Theme.Typography.editorPrThreadBody]
    ).size().width
    XCTAssertLessThanOrEqual(marker.x + width, deepest.indent)
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

  /// 項目の最初の子の表と区切り線は項目の印を字に含めず、空行なしで段落に続く表は段落の字を重ねない。
  func testRawSyntaxStartsAtItsOwnLine() {
    XCTAssertEqual(
      PrCommentMarkdown.blocks("- | a | b |\n  | - | - |").map(\.text.string),
      ["| a | b |\n| - | - |"])
    XCTAssertEqual(PrCommentMarkdown.blocks("- ***").map(\.text.string), ["***"])
    XCTAssertEqual(
      PrCommentMarkdown.blocks("説明\n| a | b |\n| - | - |\n| 1 | 2 |").map(\.text.string),
      ["説明", "| a | b |\n| - | - |\n| 1 | 2 |"])
  }

  /// 脚注は GitHub の Markdown が見せる形で出る——参照は書かれたラベルのまま（番号でないラベルも、番号が参照の順と
  /// 逆でも）、定義は本文の末尾に参照された順で、書かれた字のまま。定義の後ろの空行は字に入らない。
  func testFootnotesKeepTheirWrittenText() {
    let texts = { (source: String) in PrCommentMarkdown.blocks(source).map(\.text.string) }
    XCTAssertEqual(texts("本文[^1]\n\n[^1]: 注"), ["本文[^1]", "[^1]: 注"])
    XCTAssertEqual(texts("本文[^note]\n\n[^note]: 注"), ["本文[^note]", "[^note]: 注"])
    XCTAssertEqual(
      texts("A[^2] B[^1]\n\n[^1]: one\n[^2]: two"), ["A[^2] B[^1]", "[^2]: two", "[^1]: one"])
    XCTAssertEqual(texts("[^1]: 注\n\n後\n\n本文[^1]\n"), ["後", "本文[^1]", "[^1]: 注"])
    XCTAssertEqual(texts("A[^1]\r\n\r\n[^1]: one\r\n\r\nB"), ["A[^1]", "B", "[^1]: one"], "CRLF")
    XCTAssertEqual(texts("A[^1]\r\r[^1]: one\r\rB"), ["A[^1]", "B", "[^1]: one"], "CR だけの改行")
  }

  /// 番号の右揃えは、最後の番号でなく最も広い番号に合わせる（数字の幅は字ごとに違う）。
  func testNumbersAlignToTheWidestNumber() {
    let blocks = PrCommentMarkdown.blocks("10. a\n11. b")
    let rights = blocks.map { block in
      block.markers[0].x
        + ZoneTextLayout.width([
          ZoneTextRun(
            block.markers[0].text, font: Theme.Typography.editorPrThreadBody, color: .clear)
        ])
    }
    XCTAssertEqual(rights[0], rights[1], accuracy: 0.01)
    XCTAssertGreaterThanOrEqual(
      blocks[0].indent - rights[0], Theme.Layout.editorPrBodyListMarkerGap - 0.01)
  }
}
