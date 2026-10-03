import Foundation
import TreeSitter
import XCTest

@testable import OrbeEditorCore

/// 注入を持つ文書の構文の層の増分——編集を重ねた層の役割と注入の層の集合（深さ・言語・範囲）は、同じ本文を新しく解いた
/// ものと毎手一致し、作り直しは必ず止まる。ただし誤りを含む構文木の差分解析は、tree-sitter の誤りの回復が使い回す節に
/// 左右され、新しく解いた木と一致するとは限らない（上流の性質）。その間は役割と層の集合を比べない。誤りを直せば揃う——本文
/// が誤りを含まない層の構文木は毎手一致し、元の本文に戻せば全体が一致する。
///
/// 壊れると何が起きるか。Markdown のコードブロック・HTML の script・JS のタグ付きテンプレートを編集した後、開き直すまで
/// 誤った色が残る。フェンスに言語名を書き足しても中身に色が付かない。裏の仕事が止まらず 1 コアを使い続ける。
final class SyntaxLayersTests: XCTestCase {
  let registry = LanguageRegistry(queriesRoot: Queries.root)

  // MARK: - 乱択

  /// Markdown（見出し・インライン・強調・段落の中と外の HTML・引用・言語つきと言語なしのフェンス）。フェンスの言語名を
  /// 1 字ずつ書き足す・替える編集を含む。
  func testMarkdownFollowsRandomEdits() throws {
    let unit =
      "# Title\n\nSome *em* and `code` <b>b</b> <kbd>⌘</kbd> text.\n> quote `q`\n> more *x*\n\n```js\n"
      + "const a = `x${1}`; // c\n```\n\n```\ndef f():\n    return 1\n```\n\n```swift\nlet v = 1\n```\n\n"
      + "- item **b**\n  cont\n\n<div>\nhtml\n</div>\n\n"
    try fuzz(
      .markdown, unit: unit,
      pieces: [
        "```", "```\n", "```js\n", "```py\n", "p", "y", "py", "thon", "js", "rust", "`", "#", "*",
        "<b>", "</b>", "<kbd>", "</kbd>", "<script>", "> ", "\n", "\n\n", "x", "<div>", "---\n",
      ])
  }

  /// JS のタグ付きテンプレート（html・css を束ねる層と、html の中の style・script の子）。
  func testTaggedTemplatesFollowRandomEdits() throws {
    let unit =
      "const a = html`<div class=\"x\">${v}<span>t</span></div>`;\n"
      + "const s = css`a { color: red; }`;\n"
      + "const b = html`<style>p { color: blue; }</style><script>let y = 1;</script>`;\n"
      + "function f(x) { return x + 1; } // c\n"
    try fuzz(
      .javascript, unit: unit,
      pieces: [
        "html`", "css`", "`", "${", "}", "<div>", "</div>", "\n", "{", ";", "x", "<style>",
        "</style>", "<script>", "</script>",
      ])
  }

  /// HTML（script・style の中の JS・CSS と、その中のタグ付きテンプレート）。
  func testHTMLFollowsRandomEdits() throws {
    let unit =
      "<html>\n<script>\nconst a = html`<b>${x}</b>`;\n</script>\n<style>\na { color: red; }\n"
      + "</style>\n<p>text</p>\n"
    try fuzz(
      .html, unit: unit,
      pieces: [
        "<script>", "</script>", "<style>", "</style>", "`", "html`", "\n", "{", "}", "<", ">", "x",
      ])
  }

  /// Rust のマクロ（入れ子のマクロを含む）。
  func testRustMacrosFollowRandomEdits() throws {
    let unit = "fn f() {\n    println!(\"{}\", 1);\n    let v = vec![1, 2, foo!(3)];\n    // c\n}\n"
    try fuzz(
      .rust, unit: unit,
      pieces: ["println!(", "vec![", "foo!(", ")", "]", "\"", "{", "}", "\n", "//", "x", "!"])
  }

  /// 乱択の編集を重ね、そのあと 1 手ずつ取り消して元の本文に戻す。文書は区画 2 つに掛かり、編集の 3 回に 1 回は区画の境の
  /// 近くを狙う（境をまたぐ削除もある）。1 手は、1〜3 回の編集（編集の合間は見えている範囲だけを作る——打鍵中の裏と同じ）の
  /// 後に文書全体を作り、新しく解いたものと比べる。崩れている間に誤りを含む木が食い違っても、元の本文に戻せば揃う。
  private func fuzz(_ language: SyntaxLanguage, unit: String, pieces: [String]) throws {
    let rules = try XCTUnwrap(registry.rules(for: language))
    let source = TextRope(
      String(repeating: unit, count: SyntaxLayers.block * 5 / 4 / unit.utf16.count + 1))
    var failures: [String] = []
    var compared = 0
    for seed in UInt64(1)...2 {
      var generator = SeededGenerator(seed: seed)
      let tracker = Tracker(source, rules: rules, registry: registry)
      tracker.settle()
      var undo: [[TextEdit]] = []
      var last = Tracker.Comparison.same
      @discardableResult
      func play(_ edits: [TextEdit], _ step: String) -> [TextEdit] {
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
        switch comparison {
        case .same: compared += 1
        case .diverged: break
        case .different(let difference): failures.append("seed \(seed) の\(step): \(difference)")
        }
        last = comparison
        return inverses
      }
      for step in 0..<8 {
        var edits: [TextEdit] = []
        var text = tracker.text
        for _ in 0..<Int.random(in: 1...3, using: &generator) {
          let edit = randomEdit(of: text, pieces: pieces, using: &generator)
          text.replace(edit.range, with: edit.replacement)
          edits.append(edit)
        }
        undo.append(play(edits, " \(step) 手目"))
      }
      for (step, inverses) in undo.enumerated().reversed() {
        play(inverses.reversed(), " \(step) 手目の取り消し")
      }
      XCTAssertEqual(tracker.text.contiguousUnits(), source.contiguousUnits(), "前提: 元の本文に戻った")
      XCTAssertEqual(last, .same, "seed \(seed): 元の本文に戻せば、新しく解いたものと揃う")
    }
    XCTAssertEqual(failures, [], "\(language)")
    XCTAssertGreaterThanOrEqual(compared, 16, "前提: 比べられた手が十分ある")
  }

  /// 乱択の編集 1 つ。部品を足す・字を部品に置き換える・字を消す（区画の境をまたぎうる長さも）・行を消す／複製する。
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

  // MARK: - 決まった編集

  /// 注入の出入りと、言語だけ変わる編集。1 回の編集の後に文書全体を作り、新しく解いたものと比べる。
  func testInjectionsFollowEachEdit() throws {
    let markdown =
      "# T\n\ntext `code` and <kbd>K</kbd> here\n\n```js\nconst Foo = 1; // c\n```\n\n"
      + "```\ndef f(x):\n    return 1\n```\n\n```pytho\nclass C: pass\n```\n\nafter *em* <b>b</b>\n\n# End\n"
    let tagged =
      "const a = html`<div>${v}</div>`;\n"
      + "const b = html`<style>p { color: blue; }</style><script>let y = 1;</script>`;\n"
    let unclosed = "const a = html`<p>x</p><script>let y = 1;`;\nconst b = 1;\n"
    let split =
      "const a = html`<style>`;\nconst b = 1;\nconst c = html`p { color: red; }</style>`;\n"
    let cases = [
      EditCase("js の言語名を消す", .markdown, markdown, "js\nconst", 2, ""),
      EditCase("js → py に替える", .markdown, markdown, "js\nconst", 2, "py"),
      EditCase("開きのフェンスを消す", .markdown, markdown, "```js", 3, ""),
      EditCase("閉じのフェンスを消す", .markdown, markdown, "```\n\n```\ndef", 3, ""),
      EditCase("前にフェンスの行を足す", .markdown, markdown, "# T", 0, "```\n"),
      EditCase("見出しの # を消す", .markdown, markdown, "# T", 2, ""),
      EditCase("インラインの ` を消す", .markdown, markdown, "`code", 1, ""),
      EditCase("段落の頭を編集しても、末尾の <kbd> の層が残る", .markdown, markdown, "text `", 0, "x"),
      EditCase("段落の末尾を編集しても、頭の code の層が残る", .markdown, markdown, " here", 5, ""),
      EditCase("言語なし → python", .markdown, markdown, "```\ndef", 3, "```python"),
      EditCase("言語名を 1 字ずつ書き足す（p）", .markdown, markdown, "```\ndef", 3, "```p"),
      EditCase("未知 → 既知（pytho → python）", .markdown, markdown, "pytho\n", 5, "python"),
      EditCase("文書の末尾の見出しを行ごと消す", .markdown, markdown, "# End\n", 6, ""),
      EditCase(
        "タグを書き換えて束ねた html の部分が消えると、中の style・script の層も消える", .javascript, tagged,
        "html`<style>", 0, "x"),
      EditCase(
        "閉じていない script の後ろに、束ねた html の部分を足す", .javascript, unclosed, "const b = 1;", 12,
        "const c = html`let z = 2;</script>`;"),
      EditCase(
        "束ねた html の部分を行ごと消すと、離れた残りの部分の構文が変わる", .javascript, split,
        "const a = html`<style>`;\n", 25, ""),
    ]
    for edit in cases {
      let rules = try XCTUnwrap(registry.rules(for: edit.language))
      let tracker = Tracker(TextRope(edit.source), rules: rules, registry: registry)
      tracker.settle()
      let at = (edit.source as NSString).range(of: edit.anchor)
      XCTAssertNotEqual(at.location, NSNotFound, "前提: \(edit.name)")
      tracker.apply(
        TextEdit(
          range: NSRange(location: at.location, length: edit.removed), replacement: edit.inserted))
      tracker.settle()
      let fresh = Tracker(tracker.text, rules: rules, registry: registry)
      fresh.settle()
      XCTAssertEqual(tracker.compare(with: fresh), .same, edit.name)
    }
  }

  /// 束ねた層の節は部分の隙間をまたげる——1 つ目のタグ付きテンプレートで開いた style が、区画をまるごと覆う JS を挟んだ
  /// 2 つ目のテンプレートで閉じる。その style の子の層は、束ねた層の部分が無い区画にもマッチが掛かる。その区画でも子を戻せ
  /// ないと、外しては隣の区画で作り直すのを繰り返し、作り直しが止まらない。
  func testAChildSpanningAGapOfItsCombinedParentSettles() throws {
    let rules = try XCTUnwrap(registry.rules(for: SyntaxLanguage.javascript))
    let gap = "const s = \"" + String(repeating: "x", count: SyntaxLayers.block * 2) + "\";\n"
    let source =
      "const a = html`<style>a { color: red; }`;\n\(gap)const b = html`p { color: blue; }</style>`;\n"
    let tracker = Tracker(TextRope(source), rules: rules, registry: registry)
    tracker.settle()
    let at = (source as NSString).range(of: "p { color").location
    tracker.apply(TextEdit(range: NSRange(location: at, length: 0), replacement: "q "))
    tracker.settle()
    let fresh = Tracker(tracker.text, rules: rules, registry: registry)
    fresh.settle()
    XCTAssertEqual(tracker.compare(with: fresh), .same)
  }

  // MARK: - 補助

  /// 本文を新しく解いた構文の層。
  func parsed(_ source: String, _ language: SyntaxLanguage) throws -> SyntaxLayers {
    let layers = SyntaxLayers(
      rules: try XCTUnwrap(registry.rules(for: language)), registry: registry,
      cancellation: SyntaxCancellation())
    layers.parseAll(TextRope(source))
    return layers
  }
}

/// 決まった編集 1 つ——本文の `anchor` の位置から `removed` 字を `inserted` に置き換える。
private struct EditCase {
  let name: String
  let language: SyntaxLanguage
  let source: String
  let anchor: String
  let removed: Int
  let inserted: String

  init(
    _ name: String, _ language: SyntaxLanguage, _ source: String, _ anchor: String, _ removed: Int,
    _ inserted: String
  ) {
    self.name = name
    self.language = language
    self.source = source
    self.anchor = anchor
    self.removed = removed
    self.inserted = inserted
  }
}

/// 構文の裏の仕事（`SyntaxWorker`）と同じ手順で構文の層を同期で追う。作り直す範囲は、編集の後に根の変化と編集の区間を
/// 行に広げたものと注入の層の変化を足し、区画ずつ（見えている範囲を先に）作り直す。
final class Tracker {
  enum Comparison: Equatable {
    case same
    /// 誤りを含む構文木が、新しく解いた木と食い違った（上流の性質で、比べられない）。
    case diverged
    case different(String)
  }

  let layers: SyntaxLayers
  private(set) var text: TextRope
  private var roles: RoleRuns
  private var stale: IndexSet
  private var log = EditLog()

  init(_ text: TextRope, rules: GrammarRules, registry: LanguageRegistry) {
    layers = SyntaxLayers(rules: rules, registry: registry, cancellation: SyntaxCancellation())
    self.text = text
    layers.parseAll(text)
    roles = RoleRuns(length: text.length)
    stale = IndexSet(integersIn: 0..<text.length)
  }

  /// 編集を当て、取り消す編集を返す。
  @discardableResult
  func apply(_ edit: TextEdit) -> TextEdit {
    let removed = text.substring(edit.range)
    let start = text.point(at: edit.range.location)
    let oldEnd = text.point(at: NSMaxRange(edit.range))
    text.replace(edit.range, with: edit.replacement)
    let newEnd = text.point(at: NSMaxRange(edit.newRange))
    let record = log.append(edit, start: start, oldEnd: oldEnd, newEnd: newEnd)
    roles.apply(edit)
    stale = edit.track(stale)
    for range in layers.apply([record], text: text).rangeView {
      let first = text.lineStart(text.row(containing: min(range.lowerBound, text.length)))
      let last = text.lineEnd(text.row(containing: max(0, min(range.upperBound, text.length) - 1)))
      if first < last { stale.insert(integersIn: first..<last) }
    }
    stale.formUnion(layers.takeInvalidated())
    return TextEdit(range: edit.newRange, replacement: removed)
  }

  /// 作り直していない範囲を作り直す（`shown` があれば、そこに掛かる部分だけ）。止まらなければ失敗にする。
  func settle(shown: Range<Int>? = nil) {
    for _ in 0..<10_000 {
      let part =
        shown.map { stale.intersection(IndexSet(integersIn: $0)).rangeView.first }
        ?? stale.rangeView.first
      guard let part else { return }
      let block = (part.lowerBound / SyntaxLayers.block + 1) * SyntaxLayers.block
      let target = part.lowerBound..<min(part.upperBound, block)
      let spans = layers.roles(in: NSRange(target))
      stale.formUnion(layers.takeInvalidated())
      roles.replace(NSRange(target), with: spans)
      stale.remove(integersIn: target)
    }
    XCTFail("作り直しが止まらない")
  }

  /// 追って作った役割の並びの、`offset` 字目の役割。
  func role(at offset: Int) -> SyntaxRole? {
    roles.roles(in: NSRange(location: offset, length: 1)).first?.role
  }

  /// 役割と層の集合を `fresh`（同じ本文を新しく解いたもの）と比べる。両方にある層の構文木は、新しく解いた木が誤りを含まな
  /// ければ一致する（誤りを直せば揃う）。新しく解いた木が誤りを含み、木が食い違ったときは、役割と層の集合は比べられない。
  func compare(with fresh: Tracker) -> Comparison {
    let mine = Dictionary(grouping: layers.allLayers.map(Self.describe), by: \.layer)
    let theirs = Dictionary(grouping: fresh.layers.allLayers.map(Self.describe), by: \.layer)
    var diverged = false
    for (layer, trees) in mine {
      guard let others = theirs[layer], trees.map(\.tree).sorted() != others.map(\.tree).sorted()
      else { continue }
      guard others.contains(where: \.hasError) else {
        return .different("誤りの無い本文で構文木が違う: \(layer)")
      }
      diverged = true
    }
    let all = NSRange(location: 0, length: text.length)
    let tracked = perUnit(roles.roles(in: all))
    let rebuilt = perUnit(fresh.roles.roles(in: all))
    if let first = tracked.indices.first(where: { tracked[$0] != rebuilt[$0] }) {
      guard !diverged else { return .diverged }
      let lower = max(0, first - 30)
      let around = text.substring(NSRange(location: lower, length: min(60, text.length - lower)))
      return .different(
        "\(first) 字目の役割: 追った \(String(describing: tracked[first])) ≠ 新しく "
          + "\(String(describing: rebuilt[first])) 「\(around)」")
    }
    let mineSet = Set(mine.keys)
    let theirSet = Set(theirs.keys)
    guard mineSet != theirSet else { return .same }
    guard !diverged else { return .diverged }
    return .different(
      "層: 追った側だけ \(mineSet.subtracting(theirSet).sorted()) "
        + "新しく解いた側だけ \(theirSet.subtracting(mineSet).sorted())")
  }

  private func perUnit(_ spans: [HighlightSpan]) -> [SyntaxRole?] {
    var result = [SyntaxRole?](repeating: nil, count: text.length)
    for span in spans {
      for offset in span.range.location..<NSMaxRange(span.range) { result[offset] = span.role }
    }
    return result
  }

  /// 層（深さ・言語・束ねるか・注入の範囲を本文の上で）と、その構文木。
  private struct LayerTree {
    let layer: String
    let tree: String
    let hasError: Bool
  }

  private static func describe(_ placed: Placed) -> LayerTree {
    let ranges = placed.layer.includedRanges.map {
      "\(placed.origin + Int($0.start_byte) / 2)..<\(placed.origin + Int($0.end_byte) / 2)"
    }
    let combined = placed.layer.isCombined ? " 束ねた" : ""
    let layer = "\(placed.layer.depth) \(placed.layer.rules.grammar)\(combined) \(ranges)"
    guard let tree = placed.layer.tree, let string = ts_node_string(tree.root) else {
      return LayerTree(layer: layer, tree: "", hasError: false)
    }
    defer { free(string) }
    return LayerTree(layer: layer, tree: String(cString: string), hasError: tree.hasError)
  }
}
