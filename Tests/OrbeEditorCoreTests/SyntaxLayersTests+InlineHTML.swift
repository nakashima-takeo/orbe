import Foundation
import XCTest

@testable import OrbeEditorCore

/// Markdown の段落の中の HTML のタグは、段落ごとに 1 本の構文木——閉じタグも開きタグと対になって色が付き、別の段落の
/// タグとは対にならない。
///
/// 壊れると何が起きるか。`<kbd>⌘</kbd>` の閉じタグの名前が色無しになる（閉じタグだけの断片は HTML として解けない）。
/// 段落をまたいでタグが対になり、別の段落の閉じタグに色が付く。どちらも編集を追う側と新しく解く側が同じ誤りを持つので、
/// 乱択は緑のまま。
extension SyntaxLayersTests {
  func testAClosingInlineTagIsColoredLikeItsOpeningTag() throws {
    let source = "押すキーは <kbd>⌘</kbd>\n"
    let layers = try parsed(source, .markdown)
    XCTAssertEqual(role(of: "kbd>⌘", in: source, layers), .keyword, "前提: 開きタグの名前")
    XCTAssertEqual(role(of: "kbd>\n", in: source, layers), .keyword, "閉じタグの名前")
  }

  func testEveryInlineTagOfAParagraphIsColored() throws {
    let source = "a <kbd>⌘</kbd> + <kbd>K</kbd> and\n<b>x</b> end\n"
    let layers = try parsed(source, .markdown)
    for needle in ["kbd>⌘", "kbd> +", "kbd>K", "kbd> and", "b>x", "b> end"] {
      XCTAssertEqual(role(of: needle, in: source, layers), .keyword, needle)
    }
  }

  func testInlineTagsDoNotPairAcrossParagraphs() throws {
    let source = "a <b>x\n\ny</b> z\n"
    let layers = try parsed(source, .markdown)
    XCTAssertEqual(role(of: "b>x", in: source, layers), .keyword, "前提: 開きタグの名前")
    XCTAssertNil(role(of: "b> z", in: source, layers), "別の段落の閉じタグは対にならない")
  }

  /// 段落の中と前を編集しても（タグの間・段落の頭・前の段落・タグを足す・閉じタグの貼り直し）、閉じタグの色は追った
  /// 役割の並びに残り、新しく開いた色と揃う。
  func testInlineTagsKeepTheirColorThroughEdits() throws {
    let rules = try XCTUnwrap(registry.rules(for: SyntaxLanguage.markdown))
    let source = "# T\n\n押すキーは <kbd>⌘</kbd> です\n\nnext\n"
    let tracker = Tracker(TextRope(source), rules: rules, registry: registry)
    tracker.settle()
    let edits: KeyValuePairs<String, String> = [
      "⌘": "⌘⇧",
      "押す": "x押す",
      "# T\n": "# T\n\npara\n",
      " です": " <b>B</b> です",
      "</kbd>": "</kbd>",
    ]
    for (anchor, replacement) in edits {
      let name = "「\(anchor)」→「\(replacement)」"
      let text = tracker.text.substring(NSRange(location: 0, length: tracker.text.length))
      let at = (text as NSString).range(of: anchor)
      XCTAssertNotEqual(at.location, NSNotFound, "前提: \(name)")
      tracker.apply(TextEdit(range: at, replacement: replacement))
      tracker.settle()
      let edited = tracker.text.substring(NSRange(location: 0, length: tracker.text.length))
      let closing = (edited as NSString).range(of: "</kbd>").location + 2
      XCTAssertEqual(tracker.role(at: closing), .keyword, "\(name): 閉じタグの名前")
      let fresh = Tracker(tracker.text, rules: rules, registry: registry)
      fresh.settle()
      XCTAssertEqual(tracker.compare(with: fresh), .same, name)
    }
  }

  /// 開きタグと閉じタグが区画の境をはさむ段落。束ねた層の部分は区画ごとに問い直すので、境の両側の区画で問い直しても層を
  /// 作り直し続けず、作り直しは止まる。
  func testAParagraphWhoseTagsStraddleABlockSettles() throws {
    let rules = try XCTUnwrap(registry.rules(for: SyntaxLanguage.markdown))
    let filler = String(repeating: "x", count: SyntaxLayers.block * 2)
    let source = "a <kbd>K \(filler) y</kbd> z\n"
    let tracker = Tracker(TextRope(source), rules: rules, registry: registry)
    tracker.settle()
    let closing = (source as NSString).range(of: "</kbd>").location + 2
    XCTAssertEqual(tracker.role(at: closing), .keyword, "前提: 閉じタグの名前")
    tracker.apply(TextEdit(range: NSRange(location: closing - 4, length: 0), replacement: "w"))
    tracker.settle()
    XCTAssertEqual(tracker.role(at: closing + 1), .keyword, "編集の後も閉じタグの名前")
    let fresh = Tracker(tracker.text, rules: rules, registry: registry)
    fresh.settle()
    XCTAssertEqual(tracker.compare(with: fresh), .same)
  }
}
