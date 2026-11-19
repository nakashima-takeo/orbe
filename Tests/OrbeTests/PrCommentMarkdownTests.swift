import AppKit
import XCTest

@testable import Orbe

/// コメントの本文の Markdown を絵の段へ変換する。壊れると、インラインコードの地や太字が付かない・リンクが押せない・箇条書きや
/// 引用の字下げが崩れる・描かない記法（表・HTML・suggestion）の字が欠ける。
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
    XCTAssertEqual(blocks.map(\.marker), ["•", "•", "3.", "4.", nil, nil])
    XCTAssertEqual(blocks[0].indent, Theme.Layout.editorPrBodyListIndent)
    XCTAssertEqual(blocks[4].quoteBars, [0])
    XCTAssertEqual(blocks[4].text.string, "引用")
    XCTAssertEqual(blocks[5].kind, .code)
    XCTAssertEqual(blocks[5].text.string, "let a = 1")
  }

  /// 描かない記法は、書かれた字のまま段落になる（表・HTML の段・suggestion のコードブロック）。字は 1 つも欠けない。
  func testUnsupportedSyntaxKeepsItsWrittenText() {
    let table = "| a | b |\n| - | - |\n| 1 | 2 |"
    XCTAssertEqual(PrCommentMarkdown.blocks(table).map(\.text.string), [table])
    let suggestion = "```suggestion\nlet b = 2\n```"
    XCTAssertEqual(PrCommentMarkdown.blocks(suggestion).map(\.text.string), [suggestion])
    XCTAssertEqual(
      PrCommentMarkdown.blocks("前 <b>太</b> 後").map(\.text.string), ["前 <b>太</b> 後"])
    XCTAssertEqual(
      PrCommentMarkdown.blocks("画像 ![図](https://example.com/a.png) の後").map(\.text.string),
      ["画像 ![図](https://example.com/a.png) の後"])
  }
}
