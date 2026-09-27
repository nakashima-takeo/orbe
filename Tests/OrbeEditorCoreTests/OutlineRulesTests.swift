import Foundation
import TreeSitter
import XCTest

@testable import OrbeEditorCore

/// 15 言語の規則（`outline/<文法>.scm`）を取り出しの仕組みで回した結果——規則が今の文法の版で組め、見本の文書から
/// VS Code の既定の言語サーバに近い入れ子の木（深さ・種類・名前）が出る。
///
/// 壊れると何が起きるか。文法の版が上がって規則が組めなくなると、その言語のアウトラインが黙って消える。種類を綴り損ねた
/// パターンは何も出さない。規則を直したつもりで別のパターンが同じ節を奪い、オブジェクトのメソッドがプロパティになる。
/// 言語の口が崩れると、Swift の関数が `emit` だけになり、Go のメソッドの型が消え、HTML の要素から id と class が落ち、
/// CSS のカンマで並んだセレクタが 1 つにまとまり、JSON の配列の要素の番号がずれる。
final class OutlineRulesTests: XCTestCase {
  private let registry = LanguageRegistry(queriesRoot: Queries.root)

  /// 言語と、その見本（`Fixtures/outline/`）。期待は同じ名前に `.expected` を付けたファイル（1 行 1 シンボル、深さごとに
  /// 空白 2 つの字下げ、`種類 名前`）。
  private static let samples: [(SyntaxLanguage, String)] = [
    (.swift, "outline.swift"), (.markdown, "outline.md"), (.json, "outline.json"),
    (.typescript, "outline.ts"), (.javascript, "outline.js"), (.tsx, "outline.tsx"),
    (.css, "outline.css"), (.html, "outline.html"), (.python, "outline.py"),
    (.go, "outline.go"), (.rust, "outline.rs"), (.yaml, "outline.yaml"),
    (.toml, "outline.toml"), (.bash, "outline.sh"), (.dockerfile, "Dockerfile"),
  ]

  /// 見本を解いて、規則を根の木に 1 回かけた結果。
  private func outline(_ language: SyntaxLanguage, _ file: String) throws -> [OutlineSymbol] {
    try extract(
      language,
      String(contentsOf: Queries.outlines.appendingPathComponent(file), encoding: .utf8)
    ).symbols
  }

  /// 本文を解いて、規則を根の木に 1 回かけた結果。
  private func extract(_ language: SyntaxLanguage, _ source: String) throws -> DocumentOutline {
    let rules = try XCTUnwrap(registry.rules(for: language), "\(language) の文法が読めない")
    let query = try XCTUnwrap(rules.outline, "\(language) の規則が組めない")
    let text = TextRope(source)
    let parser = SyntaxParser(cancellation: SyntaxCancellation())
    guard
      case .parsed(let tree) = parser.parse(
        rules.language, ranges: [], old: nil, text: text, origin: 0)
    else { throw XCTSkip("前提: 解析できる") }
    let extraction = OutlineExtraction(query: query, grammar: language.grammar)
    return try XCTUnwrap(
      extraction.run(tree, text: text, version: 0, cancellation: SyntaxCancellation()))
  }

  /// 名前のシンボルの範囲（か名前の範囲）が占める字。
  private func text(
    of name: String, in outline: DocumentOutline, source: String, nameRange: Bool = false
  ) throws -> String {
    let index = try XCTUnwrap(outline.symbols.firstIndex { $0.name == name }, "\(name) が無い")
    return (source as NSString).substring(
      with: nameRange ? outline.nameRanges[index] : outline.ranges[index])
  }

  private func lines(_ symbols: [OutlineSymbol]) -> [String] {
    symbols.map { String(repeating: "  ", count: $0.depth) + "\($0.kind.rawValue) \($0.name)" }
  }

  /// 名前の道筋（最上位から）でシンボルを引く。
  private func symbol(_ path: String..., in symbols: [OutlineSymbol]) throws -> OutlineSymbol {
    var parent: Int?
    var found: Int?
    for name in path {
      found = symbols.indices.first { symbols[$0].parent == parent && symbols[$0].name == name }
      parent = try XCTUnwrap(found, "\(path.joined(separator: " › ")) が無い")
    }
    return symbols[try XCTUnwrap(found)]
  }

  private func children(of path: String..., in symbols: [OutlineSymbol]) -> [String] {
    var parent: Int?
    for name in path {
      parent = symbols.indices.first { symbols[$0].parent == parent && symbols[$0].name == name }
      if parent == nil { return [] }
    }
    return symbols.filter { $0.parent == parent }.map(\.name)
  }

  // MARK: - 規則が組める

  /// 15 言語すべてで規則が同梱物から読めて今の文法の版で組め、シンボルを出すパターン（`@item` を取る）はどれも語彙の中の
  /// 種類を持つ。`@item` を取らないパターンは注釈だけを取る。
  func testEveryLanguageHasARuleThatCompilesWithAKindForEveryPattern() throws {
    for language in SyntaxLanguage.allCases {
      let query = try XCTUnwrap(registry.rules(for: language)?.outline, "\(language) の規則が組めない")
      XCTAssertFalse(query.kinds.isEmpty, "\(language)")
      for (pattern, kind) in query.kinds.enumerated() {
        let captures = { (capture: UInt32?) in
          capture.map {
            ts_query_capture_quantifier_for_id(query.query.raw, UInt32(pattern), $0)
              != TSQuantifierZero
          } ?? false
        }
        if captures(query.item) {
          XCTAssertNotNil(kind, "\(language) のパターン \(pattern) に種類が無い（綴りの誤り）")
        } else {
          XCTAssertTrue(
            captures(query.annotation) || captures(query.adjacentAnnotation),
            "\(language) のパターン \(pattern) が何も取らない")
        }
      }
    }
    XCTAssertEqual(Set(Self.samples.map(\.0)), Set(SyntaxLanguage.allCases), "前提: 見本が全言語ある")
  }

  // MARK: - 見本の木

  /// 見本から、期待のとおりの入れ子の木（深さ・種類・名前）が出る。
  func testEachSampleYieldsTheExpectedOutline() throws {
    for (language, file) in Self.samples {
      let expected = try String(
        contentsOf: Queries.outlines.appendingPathComponent(file + ".expected"), encoding: .utf8
      ).split(separator: "\n").map(String.init)
      let actual = lines(try outline(language, file))
      XCTAssertEqual(
        actual, expected,
        "\(file):\n" + actual.joined(separator: "\n"))
    }
  }

  // MARK: - 言語の口

  /// Swift の関数・init はセレクタの形（ラベルは外部名、無ければ内部名。`_` はそのまま）。deinit は語だけ。型の本体の
  /// 中の関数は method、関数の中の関数は function。
  func testSwiftCallablesAreNamedAsSelectors() throws {
    let symbols = try outline(.swift, "outline.swift")
    XCTAssertEqual(
      children(of: "Emitter", in: symbols),
      ["Output", "isOpen", "emit(_:coalesce:)", "init(capacity:)"])
    XCTAssertEqual(
      children(of: "Channel", in: symbols).filter { $0.hasPrefix("init") || $0 == "deinit" },
      ["init(capacity:)", "init()", "deinit"])
    XCTAssertEqual(try symbol("Channel", "==(lhs:rhs:)", in: symbols).kind, .method)
    let local = try symbol("Channel", "emit(_:coalesce:)", "append(_:)", in: symbols)
    XCTAssertEqual(local.kind, .function)
    let close = try XCTUnwrap(symbols.first { $0.name == "close(reason:_:)" })
    XCTAssertEqual(close.kind, .method, "extension の中もメソッド")
    XCTAssertEqual(close.parent.map { symbols[$0].kind }, .module)
  }

  /// Swift の 1 つの宣言に並べた変数は名前ごとのシンボルで、範囲はその名前から値まで（キャレットが 2 つ目の値にあれば
  /// 2 つ目が光る）。
  func testSwiftBindingsInOneDeclarationSpanTheirOwnNameAndValue() throws {
    let source = "var first = 1, second: Int = 2\n"
    let outline = try extract(.swift, source)
    XCTAssertEqual(try text(of: "first", in: outline, source: source), "first = 1")
    XCTAssertEqual(try text(of: "second", in: outline, source: source), "second: Int = 2")
    XCTAssertEqual(try text(of: "second", in: outline, source: source, nameRange: true), "second")
  }

  /// Go の 1 つの spec に並べた const と var は名前ごとのシンボルで、範囲はその名前だけ。名前が 1 つなら spec 全体。
  func testGoNamesInOneSpecSpanOnlyTheirName() throws {
    let source = "package p\n\nconst A, B, C = 1, 2, 3\nconst D = 4\nvar x, y int\n"
    let outline = try extract(.go, source)
    XCTAssertEqual(outline.symbols.map(\.name), ["A", "B", "C", "D", "x", "y"])
    for name in ["A", "B", "C", "x", "y"] {
      XCTAssertEqual(try text(of: name, in: outline, source: source), name)
    }
    XCTAssertEqual(try text(of: "D", in: outline, source: source), "D = 4")
  }

  /// Go のメソッドは `(*Server).Start`（gopls と同じ）。関数はレシーバが無いので名前だけ。
  func testGoMethodsCarryTheirReceiverType() throws {
    let names = try outline(.go, "outline.go").filter { $0.kind == .method && $0.depth == 0 }
      .map(\.name)
    XCTAssertEqual(names, ["(*Server).Start", "(Server).Name", "(*List[T]).Push"])
  }

  /// HTML の要素は `tag#id.class1.class2`。引用符の無い値も読み、空の id・class と class の端の空白は印にしない。
  func testHTMLElementsAreNamedWithIdAndClasses() throws {
    let symbols = try outline(.html, "outline.html")
    XCTAssertEqual(children(of: "html", in: symbols), ["head", "body.page.dark"])
    XCTAssertEqual(
      children(of: "html", "body.page.dark", in: symbols),
      ["header#top.site-header.sticky", "main#content", "script"])
    XCTAssertEqual(
      children(of: "html", "body.page.dark", "main#content", in: symbols),
      ["section", "custom-card", "div.x"])
    XCTAssertEqual(
      children(of: "html", "head", in: symbols), ["meta", "title", "link", "style"],
      "自己終了タグと style も要素")
  }

  /// CSS のカンマで並んだセレクタは、1 つずつ同じ深さの兄弟になる（後ろのものが前のものの子にならない）。入れ子の
  /// rule は子になる。
  func testCSSSelectorListsSplitIntoSiblings() throws {
    let symbols = try outline(.css, "outline.css")
    let top = symbols.filter { $0.depth == 0 }.map(\.name)
    XCTAssertEqual(
      Array(top.prefix(6)),
      [
        ":root", "body", "html > main", ".card .title", ".card:hover::before",
        "#app [data-state=\"open\"]",
      ])
    XCTAssertTrue(top.contains("a:not(.external, .internal)"), "括弧の中のカンマでは分けない")
    XCTAssertEqual(
      try symbol(
        "@media screen and (min-width: 600px), print", ".card", "&:focus", in: symbols
      ).depth, 2)
  }

  /// JSON の配列の要素は、親の中での番号（前にある値の数。コメントは数えない）が名前になる。
  func testJSONArrayElementsAreNamedByTheirIndex() throws {
    let symbols = try outline(.json, "outline.json")
    XCTAssertEqual(children(of: "contributors", in: symbols), ["0", "1", "2", "3"])
    XCTAssertEqual(children(of: "contributors", "0", "roles", in: symbols), ["0", "1"])
    XCTAssertEqual(children(of: "keywords", in: symbols), ["0", "1"])
    XCTAssertEqual(try symbol("\"\"", in: symbols).kind, .key, "空のキーの名前は引用符 2 つ")
  }

  /// JSON のキーはエスケープをほどいた値（改行は `↵`）。空白だけのキーは引用符で囲む。
  func testJSONKeysAreUnescaped() throws {
    let names = try outline(.json, "outline.json").filter { $0.depth == 0 }.map(\.name)
    XCTAssertTrue(names.contains("line↵break"))
    XCTAssertTrue(names.contains("say \"hi\"!"))
    XCTAssertTrue(names.contains("\"  \""), "空白だけのキー")
  }

  /// Markdown の見出しは段で入れ子にし、範囲は次の同じか浅い段の見出しの手前まで（setext も段で並ぶ）。
  func testMarkdownHeadingsNestByLevel() throws {
    let source = "Title\n=====\n\n### Deep\n\nText\n\nSection\n-------\n\n# Next ##\n"
    let outline = try extract(.markdown, source)
    XCTAssertEqual(
      outline.symbols.map { String(repeating: "  ", count: $0.depth) + $0.name },
      ["# Title", "  ### Deep", "  ## Section", "# Next"])
    XCTAssertEqual(try text(of: "### Deep", in: outline, source: source), "### Deep\n\nText\n\n")
    XCTAssertEqual(try text(of: "# Next", in: outline, source: source), "# Next ##\n")
  }

  /// 前に続く注釈は項目の範囲に入る。Rust は rust-analyzer と同じく、属性と外側の doc コメントは空行を挟んでも、普通の
  /// コメントは空行を挟まない限り入り、内側の doc コメントでは切れる。TS はクラスの中身の前のデコレータ。
  func testLeadingAnnotationsJoinTheItemsRange() throws {
    let rust =
      "//! crate\n\n/// Doc.\n\n#[derive(Debug)]\n// plain\nstruct A;\n\n// far\n\nfn f() {}\n"
    let rustOutline = try extract(.rust, rust)
    XCTAssertEqual(
      try text(of: "A", in: rustOutline, source: rust),
      "/// Doc.\n\n#[derive(Debug)]\n// plain\nstruct A;")
    XCTAssertEqual(try text(of: "f", in: rustOutline, source: rust), "fn f() {}")

    let script = "class C {\n  x = 1;\n  @logged()\n  m() {}\n}\n"
    XCTAssertEqual(
      try text(of: "m", in: try extract(.typescript, script), source: script), "@logged()\n  m() {}"
    )
  }

  /// 飛び先は名前の字の上。Go のメソッドはメソッド名、Rust の impl は対象の型（言語サーバと同じ）。
  func testTheJumpTargetIsTheNameTheServersPointAt() throws {
    let go = "package p\n\nfunc (s *Server) Start() {}\n"
    XCTAssertEqual(
      try text(of: "(*Server).Start", in: try extract(.go, go), source: go, nameRange: true),
      "Start")
    let rust = "impl Display for Point {}\n"
    XCTAssertEqual(
      try text(
        of: "impl Display for Point", in: try extract(.rust, rust), source: rust, nameRange: true),
      "Point")
  }

  // MARK: - 同じ節の重複

  /// 同じ節を複数のパターンが取れば、規則に先に書いたパターンが勝つ（マッチの届く順ではない）。
  func testTheEarlierPatternWinsTheSameNode() throws {
    let script = try outline(.typescript, "outline.ts")
    XCTAssertEqual(
      try symbol("routes", "home", in: script).kind, .method,
      "値が関数の pair（先に書いた）が、汎用の pair（後に書いた・先に届く）に勝つ")
    XCTAssertEqual(try symbol("routes", "user", in: script).kind, .property)
    XCTAssertEqual(try symbol("Service", "constructor", in: script).kind, .constructor)
    XCTAssertEqual(try symbol("Service", "label", in: script).kind, .property, "getter はプロパティ")

    let python = try outline(.python, "outline.py")
    XCTAssertEqual(try symbol("Job", "is_exhausted", in: python).kind, .property)
    XCTAssertEqual(try symbol("MAX_RETRIES", in: python).kind, .constant)

    let go = try outline(.go, "outline.go")
    XCTAssertEqual(try symbol("Server", in: go).kind, .struct)
    XCTAssertEqual(try symbol("Store", in: go).kind, .interface)
    XCTAssertEqual(try symbol("State", in: go).kind, .class)
  }
}
