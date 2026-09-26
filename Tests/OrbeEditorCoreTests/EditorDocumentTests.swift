import Foundation
import XCTest

@testable import OrbeEditorCore

/// 文書——開く・編集を追う・保存の往復・未保存の通知・15 言語の色付け・編集後の役割。
/// 壊れると保存した内容が本文と違う、色が編集に付いてこない、未保存の印が出ない。
@MainActor
final class EditorDocumentTests: XCTestCase {
  private let registry = LanguageRegistry(queriesRoot: Queries.root)
  /// テスト 1 件の作業ディレクトリ。掘ったら消す（他ターゲットのテストと同じ流儀）。
  private var root: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-doc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
    try super.tearDownWithError()
  }

  /// 作業ディレクトリの中に、呼ぶたびに別の場所へファイルを置く。
  private func temp(_ name: String, _ text: String) throws -> URL {
    let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  private func open(_ url: URL) throws -> (EditorDocument, FakeTextSurface) {
    let contents = try EditorDocument.read(url)
    let surface = FakeTextSurface(text: contents.text)
    return (
      EditorDocument(url: url, contents: contents, surface: surface, registry: registry), surface
    )
  }

  // MARK: - 読む

  func testReadRequiresUTF8() throws {
    let url = try temp("bin", "")
    try Data([0xff, 0xfe, 0x00, 0xc3]).write(to: url)
    XCTAssertThrowsError(try EditorDocument.read(url)) { error in
      XCTAssertEqual(error as? EditorDocumentError, .notUTF8(url))
    }
    let missing = url.deletingLastPathComponent().appendingPathComponent("missing")
    XCTAssertThrowsError(try EditorDocument.read(missing)) { error in
      XCTAssertEqual(error as? EditorDocumentError, .unreadable(missing))
    }
  }

  // MARK: - 編集と保存

  func testEditThenSaveRoundTripsPreservingLineEndings() throws {
    let url = try temp("a.txt", "one\r\ntwo\n")
    let (document, surface) = try open(url)
    XCTAssertNil(document.language)
    XCTAssertFalse(document.isDirty)
    var dirtyChanges: [Bool] = []
    document.onDirtyChange = { dirtyChanges.append($0) }

    surface.replace(NSRange(location: 3, length: 0), with: "!")
    surface.replace(NSRange(location: 0, length: 0), with: "# ")
    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(dirtyChanges, [true], "実変化のときだけ通知する")
    XCTAssertEqual(
      document.text.substring(NSRange(location: 0, length: document.text.length)), surface.text,
      "写しは編集に追従する")
    XCTAssertEqual(document.text.lineCount, 3)

    try document.save()
    XCTAssertFalse(document.isDirty)
    XCTAssertEqual(dirtyChanges, [true, false])
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# one!\r\ntwo\n")
  }

  // MARK: - 色付け

  /// 見本ファイルの中で、この役割にこの文字列が塗られているはず、という 1 件。
  private struct Expectation {
    let file: String
    let role: SyntaxRole
    let text: String
    init(_ file: String, _ role: SyntaxRole, _ text: String) {
      self.file = file
      self.role = role
      self.text = text
    }
  }

  /// 15 言語の見本がそれぞれ色付きで開け、見本の中身から期待できる役割が付く。
  func testEverySampleLanguageHighlights() throws {
    let expectations: [Expectation] = [
      Expectation("sample.swift", .keyword, "struct"),
      Expectation("sample.swift", .keywordControl, "return"),
      Expectation("sample.swift", .type, "LineIndex"),
      Expectation("sample.swift", .comment, "/// 行頭オフセットの索引。"),
      Expectation("sample.md", .keyword, "Orbe"), Expectation("sample.md", .string, "open_file"),
      Expectation("sample.json", .string, "\"orbe\""), Expectation("sample.json", .keyword, "true"),
      Expectation("sample.ts", .keyword, "interface"),
      Expectation("sample.ts", .function, "normalize"),
      Expectation("sample.js", .function, "snap"),
      Expectation("sample.js", .comment, "// Snap the spine to the nearest face edge."),
      Expectation("sample.tsx", .type, "Props"), Expectation("sample.tsx", .variable, "div"),
      Expectation("sample.css", .variable, "font-size"),
      Expectation("sample.css", .comment, "/* Code view metrics from the design sample. */"),
      Expectation("sample.html", .keyword, "title"), Expectation("sample.html", .string, "\"app\""),
      Expectation("sample.py", .keyword, "class"), Expectation("sample.py", .function, "point"),
      Expectation("sample.go", .keyword, "func"), Expectation("sample.go", .string, "\"fmt\""),
      Expectation("sample.rs", .keyword, "impl"), Expectation("sample.rs", .function, "line_count"),
      Expectation("sample.yaml", .variable, "jobs"),
      Expectation("sample.yaml", .comment, "# CI matrix for the editor face."),
      Expectation("sample.toml", .comment, "# Tool pins."),
      Expectation("sample.toml", .string, "\"0.63.3\""),
      Expectation("sample.sh", .keyword, "for"), Expectation("sample.sh", .variable, "APP"),
      Expectation("Dockerfile", .keyword, "FROM"),
      Expectation("Dockerfile", .comment, "# Build image for the CLI."),
    ]
    var documents: [String: (EditorDocument, FakeTextSurface)] = [:]
    for e in expectations {
      if documents[e.file] == nil {
        documents[e.file] = try open(Queries.samples.appendingPathComponent(e.file))
      }
      let (document, surface) = documents[e.file]!
      XCTAssertNotNil(document.language, e.file)
      let texts = surface.texts(of: e.role)
      XCTAssertTrue(texts.contains(e.text), "\(e.file): \(e.role) に \(e.text) が無い: \(texts)")
    }
    XCTAssertEqual(documents.count, SyntaxLanguage.allCases.count, "15 言語すべてを見た")
  }

  /// injections: HTML の script / style の中身が JavaScript / CSS として色付く。
  func testInjectionsColorNestedLanguages() throws {
    let (document, surface) = try open(Queries.samples.appendingPathComponent("sample.html"))
    XCTAssertTrue(surface.texts(of: .function).contains("getElementById"), "script の中の JavaScript")
    XCTAssertTrue(surface.texts(of: .variable).contains("margin"), "style の中の CSS")
    withExtendedLifetime(document) {}
  }

  /// injections: Markdown のコードブロックは囲みが名乗る言語（```swift）として色付く。
  func testMarkdownFencedCodeUsesTheFenceLanguage() throws {
    let (document, surface) = try open(Queries.samples.appendingPathComponent("sample.md"))
    XCTAssertTrue(surface.texts(of: .keyword).contains("let"), "```swift の中は Swift として塗る")
    XCTAssertTrue(surface.texts(of: .variable).contains("index"), "Markdown だけでは出ない役割")
    withExtendedLifetime(document) {}
  }

  /// 編集すると構文木が追従し、編集後の本文の役割を答える。
  func testHighlightsFollowEdits() throws {
    let url = try temp("b.swift", "let a = 1\n")
    let (document, surface) = try open(url)
    XCTAssertTrue(surface.texts(of: .keyword).contains("let"))

    // 長さの変わる置換にする——構文木が編集に追従しなければ、古い区間（0..<3）の役割が新しい本文の "pub" に出る。
    surface.replace(NSRange(location: 0, length: 3), with: "public var")
    XCTAssertTrue(surface.texts(of: .keyword).contains("public"))
    XCTAssertTrue(surface.texts(of: .keyword).contains("var"))
    XCTAssertFalse(surface.texts(of: .keyword).contains("let"))

    surface.replace(NSRange(location: 17, length: 0), with: "// note\n")
    XCTAssertTrue(surface.texts(of: .comment).contains("// note"))
    XCTAssertEqual(document.text.lineCount, 3)
  }

  /// 構文木が変わらない編集でも、字の中身で役割が決まる箇所（JS の大文字で始まる識別子）の役割は正しくなる——`Foo` の
  /// F を消すと `oo` は変数の色になる。裏の仕事は、構文木が変わった区間だけでなく編集の区間に掛かる行も作り直す。
  func testRolesDecidedByTheTextFollowEditsThatKeepTheTree() throws {
    let (document, surface) = try open(try temp("c.js", "const a = Foo;\n"))
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(
      role(at: 10, in: document.roles.roles(in: NSRange(location: 10, length: 3))), .type)
    surface.replace(NSRange(location: 10, length: 1), with: "")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(
      role(at: 10, in: document.roles.roles(in: NSRange(location: 10, length: 2))), .variable)
  }

  /// 乱択の編集（字の中身で役割が決まる capture を持つ JS。1 字の削除・置換・コメントや文字列の開閉・改行を含み、
  /// 裏を待たずに続けて打つ回もある）の後、裏で追った役割の並びは、同じ本文を開き直して作ったものと一致する——
  /// ずらした前の結果の写しと、作り直す範囲の取り方に漏れが無い。
  func testRolesAfterRandomEditsEqualAFreshlyOpenedDocument() throws {
    var generator = SeededGenerator(seed: 3)
    let line = "const Foo = new Bar(\"x\"); // Baz\nlet v = Foo.qux + `t${Bar}`;\n"
    let (document, surface) = try open(
      try temp("r.js", String(repeating: line, count: 40)))
    let pieces = ["F", "x", "\"", "/*", "*/", "`", "\n", " ", "//", "Q"]
    for step in 0..<120 {
      let length = surface.length
      let location = Int.random(in: 0..<length, using: &generator)
      if Bool.random(using: &generator) {
        surface.replace(NSRange(location: location, length: 1), with: "")
      } else {
        surface.replace(
          NSRange(location: location, length: Int.random(in: 0...1, using: &generator)),
          with: pieces.randomElement(using: &generator)!)
      }
      guard step % 10 == 9 else { continue }
      XCTAssertTrue(document.waitUntilCaughtUp())
      let url = try temp("fresh.js", surface.text)
      let fresh = try open(url).0
      XCTAssertTrue(fresh.waitUntilCaughtUp())
      let all = NSRange(location: 0, length: surface.length)
      let tracked = perUnit(document.roles.roles(in: all), length: all.length)
      let rebuilt = perUnit(fresh.roles.roles(in: all), length: all.length)
      guard let first = tracked.indices.first(where: { tracked[$0] != rebuilt[$0] }) else {
        continue
      }
      let around = NSRange(
        location: max(0, first - 20), length: min(40, all.length - max(0, first - 20)))
      XCTFail(
        "\(step) 回目の \(first): \(String(describing: tracked[first])) ≠ "
          + "\(String(describing: rebuilt[first])) 「\(surface.substring(in: around))」")
    }
  }

  /// 本文が空のコードファイルでも、裏の仕事は今の版の結果を置く——初めて見せるときに上限まで待たず、追いつくのを待つ口が
  /// 時間切れにならない。全文を消して空になったときも同じ。
  func testAnEmptyCodeFileCatchesUp() throws {
    let (empty, _) = try open(try temp("e.swift", ""))
    XCTAssertTrue(empty.waitUntilCaughtUp(timeout: 1), "空で開いた")
    let (document, surface) = try open(try temp("f.swift", "let a = 1\n"))
    XCTAssertTrue(document.waitUntilCaughtUp())
    surface.replace(NSRange(location: 0, length: surface.length), with: "")
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 1), "全文を消して空になった")
  }

  /// 役割が変わらない打鍵（識別子の途中）では、裏から「役割が変わった」は届かない——面とミニマップが同じ行を塗り直さない。
  /// 役割が変わる打鍵では、変わった字が届く。
  func testOnlyEditsThatChangeRolesReportChangedRoles() throws {
    let (document, surface) = try open(try temp("g.swift", "let abc = 1\n"))
    XCTAssertTrue(document.waitUntilCaughtUp())
    let delivered = surface.changedRoles.count
    surface.replace(NSRange(location: 5, length: 0), with: "x")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(surface.changedRoles.count, delivered, "識別子の途中の打鍵では役割が変わらない")
    surface.replace(NSRange(location: 0, length: 0), with: "// ")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertTrue(
      surface.changedRoles.dropFirst(delivered).reduce(IndexSet()) { $0.union($1) }
        .contains(integersIn: 3..<6), "コメントになった let は役割が変わった")
  }

  /// 役割の答えは区間の切り方に依らない——tree-sitter は区間と交差する**マッチ**を返し、その capture は区間の外へ
  /// はみ出しうる。はみ出しを答えると、裏の仕事が文書を区切りごとに作るたびに区切りの外の字の色が変わる（Go の
  /// `NewLineIndex` が 1 文字の挿入で function 色になる）。編集の後の本文で、いろいろな位置から切った区間の答えが、
  /// 全文の答えをその区間で切ったものと一致することを見る。
  func testRolesDoNotDependOnWhereTheRangeIsCut() throws {
    for sample in ["sample.go", "sample.sh", "sample.md"] {
      let (layer, text) = try parsed(sample, inserting: "x")
      let whole = layer.roles(in: NSRange(location: 0, length: text.length), text: text)
      var mismatches: [String] = []
      for start in stride(from: 0, to: text.length, by: 7) {
        let range = NSRange(location: start, length: min(53, text.length - start))
        let expected = whole.compactMap { span -> HighlightSpan? in
          let clipped = NSIntersectionRange(span.range, range)
          return clipped.length > 0 ? HighlightSpan(range: clipped, role: span.role) : nil
        }
        if layer.roles(in: range, text: text) != expected {
          mismatches.append("\(sample) \(range)")
        }
      }
      XCTAssertEqual(mismatches, [], "区間の切り方で答えが変わった")
    }
  }

  /// 区間が文字列の途中から始まっても、その中の細かい役割（`$` と `1`）を文字列の広い capture で潰さない。injection
  /// でも同じ——Markdown のコードフェンス全体を覆う capture が、フェンスの中の Swift の `let` を潰さない。
  func testARangeStartingInsideAStringKeepsTheFineRoles() throws {
    let (shell, shellText) = try parsed("sample.sh")
    let quote = try XCTUnwrap(location(of: "\"$1\"", in: shellText))
    let roles = shell.roles(in: NSRange(location: quote + 1, length: 40), text: shellText)
    XCTAssertEqual(role(at: quote + 1, in: roles), .punctuation, "`$` は文字列の中の記号")
    XCTAssertEqual(role(at: quote + 2, in: roles), .variable, "`1` は文字列の中の変数")
    XCTAssertEqual(role(at: quote + 3, in: roles), .string)

    let (markdown, markdownText) = try parsed("sample.md")
    let keyword = try XCTUnwrap(location(of: "let index", in: markdownText))
    let fenced = markdown.roles(in: NSRange(location: keyword + 1, length: 40), text: markdownText)
    XCTAssertEqual(role(at: keyword + 1, in: fenced), .keyword, "`let` の色は区間の端で変わらない")
  }

  /// 見本を構文層で解析する（`inserting` があれば真ん中に挿入して差分解析した後）。
  private func parsed(_ sample: String, inserting insertion: String? = nil) throws -> (
    SyntaxLayer, TextRope
  ) {
    let url = Queries.samples.appendingPathComponent(sample)
    let language = try XCTUnwrap(SyntaxLanguage.detect(url: url))
    let layer = try SyntaxLayer(
      configuration: try XCTUnwrap(registry.configuration(for: language)), registry: registry)
    var text = TextRope(try String(contentsOf: url, encoding: .utf8))
    layer.parseAll(text)
    guard let insertion else { return (layer, text) }
    var log = EditLog()
    let at = text.length / 2
    let point = text.point(at: at)
    let start = TextPoint(row: point.row, column: point.column)
    text.replace(NSRange(location: at, length: 0), with: insertion)
    let edit = log.append(
      TextEdit(range: NSRange(location: at, length: 0), replacement: insertion), start: start,
      oldEnd: start,
      newEnd: TextPoint(row: point.row, column: point.column + insertion.utf16.count))
    _ = layer.didChange([edit], text: text)
    return (layer, text)
  }

  /// 字ごとの役割。
  private func perUnit(_ spans: [HighlightSpan], length: Int) -> [SyntaxRole?] {
    var result = [SyntaxRole?](repeating: nil, count: length)
    for span in spans {
      for offset in span.range.location..<NSMaxRange(span.range) { result[offset] = span.role }
    }
    return result
  }

  private func role(at offset: Int, in spans: [HighlightSpan]) -> SyntaxRole? {
    spans.first { NSLocationInRange(offset, $0.range) }?.role
  }

  /// 本文の中の文字列の位置（無ければ nil）。
  private func location(of needle: String, in text: TextRope) -> Int? {
    let range = (text.substring(NSRange(location: 0, length: text.length)) as NSString).range(
      of: needle)
    return range.location == NSNotFound ? nil : range.location
  }

  func testUnknownLanguageOpensWithoutColors() throws {
    let (document, surface) = try open(try temp("notes.txt", "let a = 1\n"))
    XCTAssertNil(document.language)
    XCTAssertTrue(surface.highlights.isEmpty)
    surface.replace(NSRange(location: 0, length: 0), with: "x")
    XCTAssertTrue(surface.highlights.isEmpty)
    XCTAssertTrue(document.isDirty)
  }

  func testFocusForwards() throws {
    let (document, surface) = try open(try temp("c.txt", ""))
    var focused: [Bool] = []
    document.onFocusChange = { focused.append($0) }
    surface.focus(true)
    surface.focus(false)
    XCTAssertEqual(focused, [true, false])
  }
}
