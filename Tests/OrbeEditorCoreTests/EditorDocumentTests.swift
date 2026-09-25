import Foundation
import XCTest

@testable import OrbeEditorCore

/// 文書——開く・編集を追う・保存の往復・未保存の通知・15 言語の色付け・編集後の塗り直し。
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
    XCTAssertEqual(document.lineIndex, LineIndex(text: surface.text), "索引は編集に追従する")

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

  /// 編集すると変わった範囲が塗り直され、編集後の本文に対して色が正しく付く。
  func testHighlightsFollowEdits() throws {
    let url = try temp("b.swift", "let a = 1\n")
    let (document, surface) = try open(url)
    XCTAssertTrue(surface.texts(of: .keyword).contains("let"))

    // 長さの変わる置換にする——塗り直しが起きなければ、古い区間（0..<3）が新しい本文の "pub" を指す。
    surface.replace(NSRange(location: 0, length: 3), with: "public var")
    XCTAssertTrue(surface.texts(of: .keyword).contains("public"))
    XCTAssertTrue(surface.texts(of: .keyword).contains("var"))
    XCTAssertFalse(surface.texts(of: .keyword).contains("let"))

    surface.replace(NSRange(location: 17, length: 0), with: "// note\n")
    XCTAssertTrue(surface.texts(of: .comment).contains("// note"))
    XCTAssertEqual(document.lineIndex.lineCount, 3)
  }

  /// 役割の答えは区間の切り方に依らない——tree-sitter は区間と交差する**マッチ**を返し、その capture は区間の外へ
  /// はみ出しうる。はみ出しを答えると、面が窓の端で問うたびに外の字の色が変わる（Go の `NewLineIndex` が 1 文字の
  /// 挿入で function 色になる）。編集の後の本文で、いろいろな位置から切った区間の答えが、全文の答えをその区間で
  /// 切ったものと一致することを見る。
  func testRolesDoNotDependOnWhereTheRangeIsCut() throws {
    for sample in ["sample.go", "sample.sh", "sample.md"] {
      let (document, surface) = try open(Queries.samples.appendingPathComponent(sample))
      surface.replace(NSRange(location: surface.length / 2, length: 0), with: "x")
      let whole = document.roleSpans(in: NSRange(location: 0, length: surface.length))
      var mismatches: [String] = []
      for start in stride(from: 0, to: surface.length, by: 7) {
        let range = NSRange(location: start, length: min(53, surface.length - start))
        let expected = whole.compactMap { span -> HighlightSpan? in
          let clipped = NSIntersectionRange(span.range, range)
          return clipped.length > 0 ? HighlightSpan(range: clipped, role: span.role) : nil
        }
        if document.roleSpans(in: range) != expected { mismatches.append("\(sample) \(range)") }
      }
      XCTAssertEqual(mismatches, [], "区間の切り方で答えが変わった")
      withExtendedLifetime(document) {}
    }
  }

  /// 区間が文字列の途中から始まっても、その中の細かい役割（`$` と `1`）を文字列の広い capture で潰さない。injection
  /// でも同じ——Markdown のコードフェンス全体を覆う capture が、フェンスの中の Swift の `let` を潰さない。
  func testARangeStartingInsideAStringKeepsTheFineRoles() throws {
    let (shell, shellSurface) = try open(Queries.samples.appendingPathComponent("sample.sh"))
    let quote = try XCTUnwrap(location(of: "\"$1\"", in: shellSurface))
    let roles = shell.roleSpans(in: NSRange(location: quote + 1, length: 40))
    XCTAssertEqual(role(at: quote + 1, in: roles), .punctuation, "`$` は文字列の中の記号")
    XCTAssertEqual(role(at: quote + 2, in: roles), .variable, "`1` は文字列の中の変数")
    XCTAssertEqual(role(at: quote + 3, in: roles), .string)

    let (markdown, markdownSurface) = try open(Queries.samples.appendingPathComponent("sample.md"))
    let keyword = try XCTUnwrap(location(of: "let index", in: markdownSurface))
    let fenced = markdown.roleSpans(in: NSRange(location: keyword + 1, length: 40))
    XCTAssertEqual(role(at: keyword + 1, in: fenced), .keyword, "`let` の色は区間の端で変わらない")
  }

  private func role(at offset: Int, in spans: [HighlightSpan]) -> SyntaxRole? {
    spans.first { NSLocationInRange(offset, $0.range) }?.role
  }

  /// 本文の中の文字列の位置（無ければ nil）。
  private func location(of needle: String, in surface: FakeTextSurface) -> Int? {
    let range = (surface.text as NSString).range(of: needle)
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
