import Foundation
import XCTest
import os

@testable import OrbeEditorCore

/// 文書とアウトラインの裏の仕事の結び目——要る間だけ打鍵が止むたびに取り直し、取り直すまでの前の結果でも位置の問いは今の
/// 本文で正しく答え、絞り込みは結果と揃えて入れ替わる。
///
/// 壊れると何が起きるか。アウトラインを閉じていても大きな文書で裏が回り続ける。打鍵のたびに取り直して 1 コアを使い続ける。
/// 取り直す前にシンボルを押すと、編集でずれた位置へ飛ぶ。絞り込みの途中で、別の結果の行が一瞬混ざる。切り替えて戻るたびに
/// 取り直して「読み込んでいます」がちらつく。
@MainActor
final class EditorDocumentOutlineTests: XCTestCase {
  private let registry = LanguageRegistry(queriesRoot: Queries.root)
  private var root: URL!

  private nonisolated static let source = """
    class Box {
      var width = 1
      func grow(by amount: Int) {
        width += amount
      }
    }

    """

  override func setUpWithError() throws {
    try super.setUpWithError()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-outline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
    try super.tearDownWithError()
  }

  func open(
    _ name: String = "box.swift", _ text: String = source,
    quietDelay: DispatchTimeInterval = SyntaxWorker.quietDelay
  ) throws -> (EditorDocument, FakeTextSurface) {
    let url = root.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    let contents = try EditorDocument.read(url)
    let surface = FakeTextSurface(text: contents.text)
    return (
      EditorDocument(
        url: url, contents: contents, surface: surface, registry: registry, quietDelay: quietDelay),
      surface
    )
  }

  func names(_ document: EditorDocument) -> [String] {
    (document.outline?.symbols ?? []).map { String(repeating: "  ", count: $0.depth) + $0.name }
  }

  func index(_ name: String, in document: EditorDocument) throws -> Int {
    try XCTUnwrap(document.outline?.symbols.firstIndex { $0.name == name })
  }

  // MARK: - いつ取り出すか

  /// 要らない間は取り出さない。要るようになったら取り出し、入れ子の木が今の版で揃う。
  func testTheOutlineIsExtractedOnlyWhileWanted() throws {
    let (document, _) = try open()
    XCTAssertTrue(document.supportsOutline)
    XCTAssertTrue(document.waitUntilCaughtUp())
    var changes = 0
    document.onOutlineChange = { changes += 1 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertNil(document.outline, "要らない間は取り出さない")
    XCTAssertEqual(changes, 0)

    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(names(document), ["Box", "  width", "  grow(by:)"])
  }

  /// 打鍵が続く間は取り直さず前の結果を出し続け、打鍵が止めば（静けさが明ければ）今の本文から取り直す。
  func testTypingKeepsThePreviousOutlineUntilTypingStops() throws {
    let (document, surface) = try open(quietDelay: .milliseconds(300))
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    let first = try XCTUnwrap(document.outline?.token)
    var changes = 0
    document.onOutlineChange = { changes += 1 }

    surface.replace(NSRange(location: 0, length: 0), with: "func top() {}\n")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(document.outline?.token, first, "打鍵の直後は取り直さない")
    XCTAssertEqual(changes, 0)

    let deadline = Date().addingTimeInterval(5)
    while document.outline?.token == first, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertEqual(names(document), ["top()", "Box", "  width", "  grow(by:)"], "静けさの後に取り直す")
    XCTAssertEqual(changes, 1)
  }

  /// 要らなくしてから戻しても、編集していなければ取り直さず同じ結果を使う（切り替えて戻っただけの文書）。
  func testSwitchingBackWithoutEditingKeepsTheResult() throws {
    let (document, _) = try open()
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    let token = document.outline?.token

    document.wantsOutline = false
    document.wantsOutline = true
    XCTAssertEqual(document.outline?.token, token, "結果は捨てない")
    var changes = 0
    document.onOutlineChange = { changes += 1 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(document.outline?.token, token, "取り直さない")
    XCTAssertEqual(changes, 0)
  }

  /// 要らない間の編集が記録で写せるうちに要るへ戻れば、前の結果を今の本文へ写して使い、取り直しも頼む。
  func testAResultThatCanReachTheCurrentTextIsKeptAndRefreshed() throws {
    let (document, surface) = try open()
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    let token = try XCTUnwrap(document.outline?.token)
    let grow = try index("grow(by:)", in: document)

    document.wantsOutline = false
    surface.replace(NSRange(location: 0, length: 0), with: "// head\n")
    document.wantsOutline = true
    XCTAssertEqual(document.outline?.token, token, "写せる結果は捨てない")
    let name = try XCTUnwrap(document.outlineNameRange(of: grow, in: token))
    XCTAssertEqual(surface.substring(in: name), "grow", "飛び先は今の本文の名前")

    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertNotEqual(document.outline?.token, token, "取り直す")
    XCTAssertEqual(document.outline?.version, document.version)
  }

  /// 要らない間に編集して、今の本文へ写せなくなった結果は、要るようになった時点で捨てる（前の本文の木を見せない）。
  func testAResultThatCannotReachTheCurrentTextIsDroppedWhenWantedAgain() throws {
    let (document, surface) = try open()
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    document.wantsOutline = false
    surface.replace(NSRange(location: 0, length: 0), with: "func top() {}\n")
    XCTAssertTrue(document.waitUntilCaughtUp())

    document.wantsOutline = true
    XCTAssertNil(document.outline, "写せない結果は見せない（読み込み中）")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(names(document).first, "top()")
  }

  /// 文法の無いファイルはアウトラインを出せない。要ると告げても待つものは無い。
  func testAFileWithoutAGrammarHasNoOutline() throws {
    let (document, _) = try open("notes.txt", "hello\n")
    XCTAssertFalse(document.supportsOutline)
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertNil(document.outline)
  }

  /// 打ち切りの印が問い合わせの途中で立てば、次のマッチを読まずに止まり、取り出しは結果を出さない（新しい写しが届いた
  /// ときの打ち切り）。
  func testACancelledExtractionStopsMidQueryWithoutAResult() throws {
    let rules = try XCTUnwrap(registry.rules(for: SyntaxLanguage.swift))
    let query = try XCTUnwrap(rules.outline)
    let text = TextRope(String(repeating: Self.source, count: 200))
    let parser = SyntaxParser(cancellation: SyntaxCancellation())
    guard
      case .parsed(let tree) = parser.parse(
        rules.language, ranges: [], old: nil, text: text, origin: 0)
    else { return XCTFail("前提: 解析できる") }
    let extraction = OutlineExtraction(query: query, grammar: .swift)
    XCTAssertEqual(
      extraction.run(tree, text: text, version: 0, cancellation: SyntaxCancellation())?.symbols
        .count, 600, "前提: 打ち切らなければ全部出る")

    let cancellation = SyntaxCancellation()
    var calls = 0
    let finished = QueryCursor().matches(
      of: query.query, in: tree.root, cancellation: cancellation, text: { _ in "" },
      each: { _ in
        calls += 1
        cancellation.cancel()
      })
    XCTAssertFalse(finished, "打ち切ったと答える")
    XCTAssertEqual(calls, 1, "印が立った後のマッチは読まない")

    let cancelled = SyntaxCancellation()
    cancelled.cancel()
    XCTAssertNil(extraction.run(tree, text: text, version: 0, cancellation: cancelled))
  }

  // MARK: - 位置の問い

  /// 取り直す前の結果でも、飛び先と「今の位置を含むシンボル」は今の本文の位置で答える。
  func testQuestionsAboutPositionsAreAnsweredOnTheCurrentText() throws {
    let (document, surface) = try open(quietDelay: .seconds(30))
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    let outline = try XCTUnwrap(document.outline)
    let grow = try index("grow(by:)", in: document)
    let nameBefore = try XCTUnwrap(document.outlineNameRange(of: grow, in: outline.token))
    XCTAssertEqual(surface.substring(in: nameBefore), "grow")

    surface.replace(NSRange(location: 0, length: 0), with: "// head\n")
    XCTAssertEqual(document.outline?.token, outline.token, "前提: まだ取り直していない")
    let name = try XCTUnwrap(document.outlineNameRange(of: grow, in: outline.token))
    XCTAssertEqual(surface.substring(in: name), "grow", "飛び先は今の本文の名前")
    let body = (surface.text as NSString).range(of: "width += amount")
    XCTAssertEqual(document.outlineSymbol(containing: body.location, in: outline.token), grow)
    XCTAssertNil(
      document.outlineSymbol(containing: surface.length, in: outline.token), "型の外はどのシンボルにも入らない")

    let range = try XCTUnwrap(document.outlineRange(of: grow, in: outline.token))
    XCTAssertTrue(surface.substring(in: range).hasPrefix("func grow"))
    XCTAssertTrue(surface.substring(in: range).hasSuffix("}"))
  }

  /// シンボルの本体を直しても範囲は消えずに伸び縮みし、名前を丸ごと書き換えたら飛び先は範囲の頭になる。
  func testEditingInsideASymbolKeepsItAndARewrittenNameFallsBackToItsHead() throws {
    let (document, surface) = try open(quietDelay: .seconds(30))
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    let token = try XCTUnwrap(document.outline?.token)
    let grow = try index("grow(by:)", in: document)

    let body = (surface.text as NSString).range(of: "amount\n")
    surface.replace(NSRange(location: body.location, length: 6), with: "amount * 2")
    let caret = (surface.text as NSString).range(of: "* 2").location
    XCTAssertEqual(document.outlineSymbol(containing: caret, in: token), grow)

    let name = (surface.text as NSString).range(of: "grow")
    surface.replace(name, with: "enlarge")
    let target = try XCTUnwrap(document.outlineNameRange(of: grow, in: token))
    XCTAssertEqual(target.length, 0)
    XCTAssertEqual(target.location, (surface.text as NSString).range(of: "func enlarge").location)
  }

  /// 見せている結果と違う結果の番号での問いには答えない（次の結果で列が作り直される）。
  func testQuestionsWithAnotherTokenAreNotAnswered() throws {
    let (document, _) = try open()
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    let stale = OutlineExtraction.nest([], version: 0).token
    XCTAssertNil(document.outlineNameRange(of: 0, in: stale))
    XCTAssertNil(document.outlineSymbol(containing: 0, in: stale))
  }

  // MARK: - 手放す

  /// 取り直しで外れた前の結果は、知らせの後に裏へ渡して手放す（シンボルの数に比例する解放を main で行わない）。
  func testARefreshHandsThePreviousOutlineToTheBackground() throws {
    let (document, surface) = try open(quietDelay: .milliseconds(50))
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    let previous = try XCTUnwrap(document.outline?.token)
    let notified = OSAllocatedUnfairLock(initialState: false)
    document.onOutlineChange = { notified.withLock { $0 = true } }
    let handed = OSAllocatedUnfairLock(initialState: [(token: OutlineToken, afterNotice: Bool)]())
    document.releaseOutlines = { parcel in
      let tokens = parcel.withLock { $0?.outlines.map(\.token) ?? [] }
      let afterNotice = notified.withLock { $0 }
      handed.withLock { $0 += tokens.map { ($0, afterNotice) } }
    }

    surface.replace(NSRange(location: 0, length: 0), with: "func top() {}\n")
    XCTAssertTrue(document.waitUntilCaughtUp())
    let released = handed.withLock { $0 }
    XCTAssertEqual(released.map(\.token), [previous])
    XCTAssertEqual(released.map(\.afterNotice), [true], "知らせの後に渡す")
  }

  // MARK: - 閉じる

  /// 閉じた文書のアウトラインの裏の仕事（結果を持つ）は、手放す裏の仕事が最後の参照を落とす。
  func testClosingHandsTheOutlineToTheBackground() throws {
    let result = OSAllocatedUnfairLock<(saw: Bool, aliveAfterDrop: Bool)?>(initialState: nil)
    do {
      let (document, _) = try open()
      document.wantsOutline = true
      XCTAssertTrue(document.waitUntilCaughtUp())
      document.releaseParts = { parcel in
        weak let worker = parcel.withLock { $0?.outline.worker }
        let saw =
          worker != nil && parcel.withLock { $0?.outline.retired.outlines.isEmpty == false }
        DispatchQueue.global().sync { parcel.withLock { $0 = nil } }
        result.withLock { $0 = (saw, worker != nil) }
      }
    }
    let observed = try XCTUnwrap(result.withLock { $0 }, "前提: 文書が閉じて部品を手放した")
    XCTAssertTrue(observed.saw, "前提: アウトラインの裏の仕事と結果を手放す部品に入れた")
    XCTAssertFalse(observed.aliveAfterDrop, "裏で落とした後に main がアウトラインの裏の仕事を持っていない")
  }
}
