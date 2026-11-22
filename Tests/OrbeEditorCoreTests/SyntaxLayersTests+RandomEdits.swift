import Foundation
import OrbeTestSupport
import XCTest

@testable import OrbeEditorCore

/// 乱択の編集を重ねても、構文の層が新しく解いたものと毎手一致する（`SyntaxLayersTests` の性質を、乱択の手で確かめる）。
///
/// 小さい段は重ねた手をそこで取り消し、全部の段はその後も手を重ねてから取り消すので、小さい段の取り消しの手は、全部の段に
/// 無い。
extension SyntaxLayersTests {
  private static let randomEditSeeds: [UInt64] = [1, 2]

  /// Markdown（見出し・インライン・強調・段落の中と外の HTML・引用・言語つきと言語なしのフェンス）。フェンスの言語名を
  /// 1 字ずつ書き足す・替える編集を含む。
  private static let markdown = RandomEditInput(
    .markdown,
    unit:
      "# Title\n\nSome *em* and `code` <b>b</b> <kbd>⌘</kbd> text.\n> quote `q`\n> more *x*\n\n```js\n"
      + "const a = `x${1}`; // c\n```\n\n```\ndef f():\n    return 1\n```\n\n```swift\nlet v = 1\n```\n\n"
      + "- item **b**\n  cont\n\n<div>\nhtml\n</div>\n\n",
    pieces: [
      "```", "```\n", "```js\n", "```py\n", "p", "y", "py", "thon", "js", "rust", "`", "#", "*",
      "<b>", "</b>", "<kbd>", "</kbd>", "<script>", "> ", "\n", "\n\n", "x", "<div>", "---\n",
    ])

  /// JS のタグ付きテンプレート（html・css を束ねる層と、html の中の style・script の子）。
  private static let taggedTemplates = RandomEditInput(
    .javascript,
    unit: "const a = html`<div class=\"x\">${v}<span>t</span></div>`;\n"
      + "const s = css`a { color: red; }`;\n"
      + "const b = html`<style>p { color: blue; }</style><script>let y = 1;</script>`;\n"
      + "function f(x) { return x + 1; } // c\n",
    pieces: [
      "html`", "css`", "`", "${", "}", "<div>", "</div>", "\n", "{", ";", "x", "<style>",
      "</style>", "<script>", "</script>",
    ])

  /// HTML（script・style の中の JS・CSS と、その中のタグ付きテンプレート）。
  private static let html = RandomEditInput(
    .html,
    unit: "<html>\n<script>\nconst a = html`<b>${x}</b>`;\n</script>\n<style>\na { color: red; }\n"
      + "</style>\n<p>text</p>\n",
    pieces: [
      "<script>", "</script>", "<style>", "</style>", "`", "html`", "\n", "{", "}", "<", ">", "x",
    ])

  /// Rust のマクロ（入れ子のマクロを含む）。
  private static let rustMacros = RandomEditInput(
    .rust,
    unit: "fn f() {\n    println!(\"{}\", 1);\n    let v = vec![1, 2, foo!(3)];\n    // c\n}\n",
    pieces: ["println!(", "vec![", "foo!(", ")", "]", "\"", "{", "}", "\n", "//", "x", "!"])

  func testMarkdownFollowsRandomEdits() throws {
    try fuzz(Self.markdown, seeds: Self.randomEditSeeds.prefix(1), steps: 5)
  }

  func testMarkdownFollowsRandomEditsAtFullScale() throws {
    try Fuzz.skipFullScaleIfExcluded()
    try fuzz(Self.markdown, seeds: Self.randomEditSeeds, steps: 8)
  }

  func testTaggedTemplatesFollowRandomEdits() throws {
    try fuzz(Self.taggedTemplates, seeds: Self.randomEditSeeds.prefix(1), steps: 5)
  }

  func testTaggedTemplatesFollowRandomEditsAtFullScale() throws {
    try Fuzz.skipFullScaleIfExcluded()
    try fuzz(Self.taggedTemplates, seeds: Self.randomEditSeeds, steps: 8)
  }

  func testHTMLFollowsRandomEdits() throws {
    try fuzz(Self.html, seeds: Self.randomEditSeeds.prefix(1), steps: 5)
  }

  func testHTMLFollowsRandomEditsAtFullScale() throws {
    try Fuzz.skipFullScaleIfExcluded()
    try fuzz(Self.html, seeds: Self.randomEditSeeds, steps: 8)
  }

  func testRustMacrosFollowRandomEdits() throws {
    try fuzz(Self.rustMacros, seeds: Self.randomEditSeeds.prefix(1), steps: 5)
  }

  func testRustMacrosFollowRandomEditsAtFullScale() throws {
    try Fuzz.skipFullScaleIfExcluded()
    try fuzz(Self.rustMacros, seeds: Self.randomEditSeeds, steps: 8)
  }

  /// 種ごとに、乱択の編集を `steps` 手重ね、そのあと 1 手ずつ取り消して元の本文に戻す。文書は格子の目 2 つに掛かり、編集の
  /// 3 回に 1 回は格子の切れ目の近くを狙う（切れ目をまたぐ削除もある）。1 手は、1〜3 回の編集（編集の合間は見えている範囲
  /// だけを作る——打鍵中の裏と同じ）の後に文書全体を作り、新しく解いたものと比べる。崩れている間に誤りを含む木が食い違っても、
  /// 元の本文に戻せば揃う。最初に失敗した手で止める。
  private func fuzz(_ input: RandomEditInput, seeds: some Sequence<UInt64>, steps: Int) throws {
    let language = input.language
    let rules = try XCTUnwrap(registry.rules(for: language))
    let source = TextRope(
      String(repeating: input.unit, count: SyntaxLayers.block * 5 / 4 / input.unit.utf16.count + 1))
    var comparisons = 0
    var compared = 0
    for seed in seeds {
      var generator = SeededGenerator(seed: seed)
      let tracker = Tracker(source, rules: rules, registry: registry)
      tracker.settle()
      var last = Tracker.Comparison.same
      func play(_ edits: [TextEdit]) -> [TextEdit] {
        var inverses: [TextEdit] = []
        for edit in edits {
          inverses.append(tracker.apply(edit))
          let shown = Int.random(in: 0...tracker.text.length, using: &generator)
          tracker.settle(shown: shown..<min(tracker.text.length, shown + 3000))
        }
        tracker.settle()
        let fresh = Tracker(tracker.text, rules: rules, registry: registry)
        fresh.settle()
        let comparison = tracker.compare(with: fresh)
        comparisons += 1
        switch comparison {
        case .same: compared += 1
        case .diverged: break
        case .different(let difference): XCTFail(difference)
        }
        last = comparison
        return inverses
      }
      var undo: [[TextEdit]] = []
      for step in 0..<steps {
        let passed = Fuzz.step(self, "\(language) seed \(seed) の \(step) 手目") {
          var edits: [TextEdit] = []
          var text = tracker.text
          for _ in 0..<Int.random(in: 1...3, using: &generator) {
            let edit = randomEdit(of: text, pieces: input.pieces, using: &generator)
            text.replace(edit.range, with: edit.replacement)
            edits.append(edit)
          }
          undo.append(play(edits))
        }
        guard passed else { return }
      }
      for (step, inverses) in undo.enumerated().reversed() {
        let passed = Fuzz.step(self, "\(language) seed \(seed) の \(step) 手目の取り消し") {
          _ = play(inverses.reversed())
        }
        guard passed else { return }
      }
      let returned = Fuzz.step(self, "\(language) seed \(seed)") {
        XCTAssertEqual(tracker.text.contiguousUnits(), source.contiguousUnits(), "前提: 元の本文に戻った")
        XCTAssertEqual(last, .same, "seed \(seed): 元の本文に戻せば、新しく解いたものと揃う")
      }
      guard returned else { return }
    }
    XCTAssertGreaterThanOrEqual(
      compared * 2, comparisons, "前提: 比べようとした手の半分以上で、誤りを含む木が食い違わずに比べられた")
  }

  /// 乱択の編集 1 つ。部品を足す・字を部品に置き換える・字を消す（格子の切れ目をまたぎうる長さも）・行を消す／複製する。
  private func randomEdit(
    of text: TextRope, pieces: [String], using generator: inout SeededGenerator
  ) -> TextEdit {
    let length = text.length
    let location =
      Int.random(in: 0..<3, using: &generator) == 0
      ? min(length, max(0, SyntaxLayers.block + Int.random(in: -200...200, using: &generator)))
      : Int.random(in: 0...length, using: &generator)
    let piece = pieces.randomElement(using: &generator)!
    switch Int.random(in: 0..<10, using: &generator) {
    case 0..<5:
      return TextEdit(range: NSRange(location: location, length: 0), replacement: piece)
    case 5..<7:
      let removed = min(length - location, Int.random(in: 1...8, using: &generator))
      return TextEdit(range: NSRange(location: location, length: removed), replacement: piece)
    case 7..<9:
      let removed = min(length - location, Int.random(in: 1...300, using: &generator))
      return TextEdit(range: NSRange(location: location, length: removed), replacement: "")
    default:
      let row = text.row(containing: min(location, max(0, length - 1)))
      let line = NSRange(
        location: text.lineStart(row), length: text.lineEnd(row) - text.lineStart(row))
      return Bool.random(using: &generator)
        ? TextEdit(range: line, replacement: "")
        : TextEdit(
          range: NSRange(location: line.location, length: 0), replacement: text.substring(line))
    }
  }
}

/// 乱択の編集の入力——言語 `language` の本文の組 `unit` と、編集で足す部品 `pieces`。
private struct RandomEditInput {
  let language: SyntaxLanguage
  let unit: String
  let pieces: [String]

  init(_ language: SyntaxLanguage, unit: String, pieces: [String]) {
    self.language = language
    self.unit = unit
    self.pieces = pieces
  }
}
