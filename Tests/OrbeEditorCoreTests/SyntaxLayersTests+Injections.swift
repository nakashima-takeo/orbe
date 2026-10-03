import Foundation
import XCTest

@testable import OrbeEditorCore

/// 新しく開いた文書の注入の意味——注入は 1 つずつ別の構文木で、束ねるのは規則が束ねると指定したものだけ、注入の範囲は
/// 中身から名前付きの子を除いたもの。
///
/// 壊れると何が起きるか。Markdown のコードブロックの `/*` が次のコードブロックまで続き、間の見出しがコメント色になる。
/// 段落をまたいでコードスパンができる。引用の中のコードスパンで行頭の `>` まで文字列の色になる。タグ付きテンプレートの
/// `${}` の後ろの断片が前の断片と繋がらず、CSS の性質の名前が色を失う。編集を追う側と新しく解く側が同じ誤りを持てば
/// 乱択は緑のままなので、ここで意味そのものを見る。
extension SyntaxLayersTests {
  /// 同じ言語のコードブロックでも別の構文木——1 つ目の閉じない `/*` は、次のコードブロックへ続かない。
  func testACodeBlockDoesNotContinueIntoTheNextOne() throws {
    let source = "```js\nlet a = 1 /* open\n```\n\n# Heading\n\n```js\nlet b = 2 */ + 3\n```\n"
    let layers = try parsed(source, .markdown)
    XCTAssertNotEqual(role(of: "Heading", in: source, layers), .comment, "間の見出しはコメントではない")
    XCTAssertEqual(role(of: "let b", in: source, layers), .keyword, "2 つ目のコードブロックはコードとして始まる")
  }

  /// 段落ごとに別の構文木——開いたままの `` ` `` は、次の段落の `` ` `` とコードスパンを作らない。
  func testAnInlineBacktickDoesNotSpanParagraphs() throws {
    let source = "a `b\n\nc` d\n"
    let layers = try parsed(source, .markdown)
    XCTAssertEqual(role(of: "b", in: source, layers), nil)
    XCTAssertEqual(role(of: "c", in: source, layers), nil)
  }

  /// 注入の範囲は中身から名前付きの子（引用の段落の続きの `>`）を除く——引用の中で行をまたぐコードスパンは、行頭の `>` を
  /// 挟んだまま 1 つのコードスパンになり、`>` は文字列の色にならない。
  func testQuoteMarksAreOutsideTheInlineInjection() throws {
    let source = "> `a\n> b`\n"
    let layers = try parsed(source, .markdown)
    XCTAssertEqual(role(of: "a", in: source, layers), .string, "前提: 行をまたぐコードスパン")
    XCTAssertEqual(role(of: "b", in: source, layers), .string, "前提: 行をまたぐコードスパン")
    XCTAssertNotEqual(role(of: "> b", in: source, layers), .string, "続きの `>` は注入の外")
  }

  /// 規則が束ねると指定した注入（タグ付きテンプレートの `${}` で割れた断片）は 1 本の構文木——`${}` の後ろの断片は、前の
  /// 断片で開いた宣言の塊の続き。
  func testTaggedTemplatePiecesAreOneTree() throws {
    let source = "const a = css`a { color: ${c}; margin: 0 }`;\n"
    let layers = try parsed(source, .javascript)
    XCTAssertEqual(role(of: "color", in: source, layers), .variable, "前提: 宣言の塊の中の性質の名前")
    XCTAssertEqual(role(of: "margin", in: source, layers), .variable, "`${}` の後ろも同じ宣言の塊の続き")
  }

  /// 文書全体の役割のうち、本文の `needle` の最初の字の役割。
  func role(of needle: String, in source: String, _ layers: SyntaxLayers) -> SyntaxRole? {
    let at = (source as NSString).range(of: needle).location
    XCTAssertNotEqual(at, NSNotFound, "前提: 本文に \(needle) がある")
    return layers.roles(in: NSRange(location: 0, length: source.utf16.count))
      .first { NSLocationInRange(at, $0.range) }?.role
  }
}
