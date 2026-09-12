import Foundation
import XCTest

@testable import OrbeEditorCore

/// 文書——開く・編集を追う・保存の往復・未保存の通知・15 言語の色付け・編集後の塗り直し。
/// 壊れると保存した内容が本文と違う、色が編集に付いてこない、未保存の印が出ない。
@MainActor
final class EditorDocumentTests: XCTestCase {
  private let registry = LanguageRegistry(queriesRoot: Queries.root)

  private func temp(_ name: String, _ text: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-doc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  private func open(_ url: URL) throws -> (EditorDocument, FakeTextSurface) {
    let surface = FakeTextSurface(text: try EditorDocument.read(url))
    return (EditorDocument(url: url, surface: surface, registry: registry), surface)
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
      Expectation("sample.md", .keyword, "Orbe"), Expectation("sample.md", .string, "`open_file`"),
      Expectation("sample.json", .string, "\"orbe\""), Expectation("sample.json", .keyword, "true"),
      Expectation("sample.ts", .keyword, "interface"),
      Expectation("sample.ts", .function, "normalize"),
      Expectation("sample.js", .function, "snap"),
      Expectation("sample.js", .comment, "// Snap the spine to the nearest face edge."),
      Expectation("sample.tsx", .type, "Props"), Expectation("sample.tsx", .keyword, "div"),
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
    let (_, surface) = try open(Queries.samples.appendingPathComponent("sample.html"))
    XCTAssertTrue(surface.texts(of: .function).contains("getElementById"), "script の中の JavaScript")
    XCTAssertTrue(surface.texts(of: .variable).contains("margin"), "style の中の CSS")
  }

  /// injections: Markdown のコードブロックは囲みが名乗る言語（```swift）として色付く。
  func testMarkdownFencedCodeUsesTheFenceLanguage() throws {
    let (_, surface) = try open(Queries.samples.appendingPathComponent("sample.md"))
    XCTAssertTrue(surface.texts(of: .keyword).contains("let"), "```swift の中は Swift として塗る")
    XCTAssertTrue(surface.texts(of: .variable).contains("index"), "Markdown だけでは出ない役割")
  }

  /// 編集すると変わった範囲が塗り直され、編集後の本文に対して色が正しく付く。
  func testHighlightsFollowEdits() throws {
    let url = try temp("b.swift", "let a = 1\n")
    let (document, surface) = try open(url)
    XCTAssertTrue(surface.texts(of: .keyword).contains("let"))
    let applied = surface.applied

    surface.replace(NSRange(location: 0, length: 3), with: "var")
    XCTAssertGreaterThan(surface.applied, applied)
    XCTAssertTrue(surface.texts(of: .keyword).contains("var"))
    XCTAssertFalse(surface.texts(of: .keyword).contains("let"))

    surface.replace(NSRange(location: 10, length: 0), with: "// note\n")
    XCTAssertTrue(surface.texts(of: .comment).contains("// note"))
    XCTAssertEqual(document.lineIndex.lineCount, 3)

    document.rehighlightAll()
    XCTAssertTrue(surface.texts(of: .keyword).contains("var"))
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
