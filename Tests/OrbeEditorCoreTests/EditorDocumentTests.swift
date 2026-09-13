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

    // 長さの変わる置換にする——塗り直しが起きなければ、古い区間（0..<3）が新しい本文の "pub" を指す。
    surface.replace(NSRange(location: 0, length: 3), with: "public var")
    XCTAssertTrue(surface.texts(of: .keyword).contains("public"))
    XCTAssertTrue(surface.texts(of: .keyword).contains("var"))
    XCTAssertFalse(surface.texts(of: .keyword).contains("let"))

    surface.replace(NSRange(location: 17, length: 0), with: "// note\n")
    XCTAssertTrue(surface.texts(of: .comment).contains("// note"))
    XCTAssertEqual(document.lineIndex.lineCount, 3)
  }

  /// 打鍵で塗るのは塗り直す区間の中だけ——tree-sitter は区間と交差する**マッチ**を返し、その capture は
  /// 区間の外へはみ出しうる。はみ出しを塗ると外の正しい色が潰れる（Go の `NewLineIndex` が 1 文字の
  /// 挿入で function 色になる）。全位置へ 1 文字挿入し、塗った区間がすべて塗り直す区間の中に収まり、
  /// その外の色が動かないことを見る。
  func testEditingPaintsOnlyInsideTheChangedRanges() throws {
    let source = try String(contentsOf: Queries.samples.appendingPathComponent("sample.go"))
    var strays: [String] = []
    var recolored: [String] = []
    var narrowEdits = 0
    for position in 0...source.utf16.count {
      // 文書は面の delegate を weak で持たれるので、編集の間は生かしておく。
      let (document, surface) = try open(try temp("edit.go", source))
      let before = (0..<surface.length).map { surface.role(at: $0) }
      surface.replace(NSRange(location: position, length: 0), with: "x")
      XCTAssertEqual(surface.appliedRanges.count, 2, "編集の塗りは 1 回の applyHighlights にまとまる")
      let painted = try XCTUnwrap(surface.appliedRanges.last)
      let spans = try XCTUnwrap(surface.appliedSpans.last)
      if !painted.contains(integersIn: 0..<surface.length) { narrowEdits += 1 }
      for span in spans where !painted.contains(integersIn: Range(span.range)!) {
        strays.append("挿入 \(position) → \(span.range) \(span.role)")
      }
      for offset in 0..<surface.length where !painted.contains(offset) && offset != position {
        let old = offset < position ? offset : offset - 1
        if surface.role(at: offset) != before[old] {
          recolored.append("挿入 \(position) → offset \(offset)")
        }
      }
      withExtendedLifetime(document) {}
    }
    XCTAssertEqual(strays, [], "塗り直す区間からはみ出して塗った")
    XCTAssertEqual(recolored, [], "塗り直す区間の外の色が動いた")
    XCTAssertGreaterThan(narrowEdits, 0, "全文を塗り直す編集ばかりでは外を見ていない")
  }

  /// スクロールで新しく見えた区間を塗るとき、その手前にある画面内の字を潰さない——塗り直す区間が可視
  /// 区間の真部分集合になるのはこの経路だけで、区間をまたぐ広い capture（文字列）が、区間の外にある
  /// 細かい capture（文字列の中の `$` と `1`）の色を潰しうる。
  func testScrollingIntoTheMiddleOfAStringKeepsTheColorsBeforeIt() throws {
    let (document, surface) = try open(Queries.samples.appendingPathComponent("sample.sh"))
    let quote = try XCTUnwrap(location(of: "\"$1\"", in: surface))
    XCTAssertEqual(surface.role(at: quote), .string)
    XCTAssertEqual(surface.role(at: quote + 1), .punctuation, "前提: `$` は文字列の中の記号")
    XCTAssertEqual(surface.role(at: quote + 2), .variable, "前提: `1` は文字列の中の変数")

    surface.visibleRange = NSRange(location: 0, length: 4)
    surface.replace(NSRange(location: 2, length: 0), with: " ")
    surface.scroll(to: NSRange(location: quote + 3, length: 40))

    XCTAssertEqual(surface.role(at: quote + 2), .punctuation, "`$` の色は動かない")
    XCTAssertEqual(surface.role(at: quote + 3), .variable, "`1` の色は動かない")
    XCTAssertEqual(surface.role(at: quote + 4), .string)
    withExtendedLifetime(document) {}
  }

  /// injection でも同じ——Markdown のコードフェンス全体を覆う capture（文字列）が、フェンスの中の
  /// Swift の `let`（区間の外）を潰さない。
  func testScrollingIntoAFencedCodeBlockKeepsTheInnerColorsBeforeIt() throws {
    let (document, surface) = try open(Queries.samples.appendingPathComponent("sample.md"))
    let keyword = try XCTUnwrap(location(of: "let index", in: surface))
    XCTAssertEqual(surface.role(at: keyword), .keyword, "前提: フェンスの中の Swift が色付く")

    surface.visibleRange = NSRange(location: 0, length: 4)
    surface.replace(NSRange(location: 2, length: 0), with: " ")
    surface.scroll(to: NSRange(location: keyword + 4, length: 40))

    XCTAssertEqual(surface.role(at: keyword + 1), .keyword, "`let` の色は動かない")
    withExtendedLifetime(document) {}
  }

  /// 本文の中の文字列の位置（無ければ nil）。
  private func location(of needle: String, in surface: FakeTextSurface) -> Int? {
    let range = (surface.text as NSString).range(of: needle)
    return range.location == NSNotFound ? nil : range.location
  }

  /// 編集のたびに見えている区間を塗り直す（木の差分に出ない隣の役割変化を画面に残さない）。
  /// 見えていない区間は次に見えたとき 1 回だけ塗り、動かなければ塗らない。
  func testEditsRepaintTheVisibleRangeAndScrollingPaintsStaleRangesOnce() throws {
    let (document, surface) = try open(Queries.samples.appendingPathComponent("sample.go"))
    let length = surface.length
    surface.visibleRange = NSRange(location: 100, length: 80)

    // コメントの中への挿入——構文木の変化はそのコメントに閉じる。
    let comment = try XCTUnwrap(location(of: "// ", in: surface)) + 2
    surface.replace(NSRange(location: comment, length: 0), with: " ")
    let painted = try XCTUnwrap(surface.appliedRanges.last)
    XCTAssertTrue(painted.contains(integersIn: 100..<180), "編集で可視区間を塗り直す")
    XCTAssertTrue(painted.contains(comment), "変わった区間も塗る")
    XCTAssertFalse(painted.contains(length - 1), "見えていない末尾は塗らない")

    let before = surface.appliedRanges.count
    surface.scroll(to: NSRange(location: 120, length: 40))
    XCTAssertEqual(surface.appliedRanges.count, before, "塗り済みの中で動いても塗らない")

    surface.scroll(to: NSRange(location: length - 50, length: 200))
    XCTAssertEqual(surface.appliedRanges.count, before + 1, "初めて見える区間は塗る")
    let stale = try XCTUnwrap(surface.appliedRanges.last)
    XCTAssertTrue(stale.contains(integersIn: (length - 50)..<(length + 1)), "本文の長さに収めて塗る")
    XCTAssertFalse(stale.contains(150), "塗り済みは含めない")

    surface.scroll(to: NSRange(location: length - 50, length: 200))
    XCTAssertEqual(surface.appliedRanges.count, before + 1, "同じ区間へ戻っても塗らない")
    withExtendedLifetime(document) {}
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
