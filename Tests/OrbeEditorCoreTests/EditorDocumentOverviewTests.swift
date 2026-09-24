import Foundation
import XCTest

@testable import OrbeEditorCore

/// 文書が俯瞰と検索へ出す口——インデント単位は文書が検出して面へ押す（開いたとき・丸ごと置き換え）、役割の区間は
/// 構文木から窓ごとに答える、本文・選択・viewport の変化はそれぞれ 1 本の closure で届く（本文は構文木の更新の後）。
@MainActor
final class EditorDocumentOverviewTests: XCTestCase {
  private let registry = LanguageRegistry(queriesRoot: Queries.root)
  private var root: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-overview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
    try super.tearDownWithError()
  }

  private struct Opened {
    let document: EditorDocument
    let surface: FakeTextSurface
    let url: URL
  }

  private func open(_ name: String, _ text: String) throws -> Opened {
    let url = root.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    let contents = try EditorDocument.read(url)
    let surface = FakeTextSurface(text: contents.text)
    return Opened(
      document: EditorDocument(url: url, contents: contents, surface: surface, registry: registry),
      surface: surface, url: url)
  }

  func testIndentUnitIsDetectedOnOpenAndOnReplaceFromDiskAndPushedToTheSurface() throws {
    let opened = try open("a.swift", "a\n  b\n    c\n  d\n")
    let (document, surface, url) = (opened.document, opened.surface, opened.url)
    XCTAssertEqual(document.indentUnit, 2)
    XCTAssertEqual(surface.indentUnit, 2, "開いたとき面へ押す")

    try Data("a\n    b\n        c\n".utf8).write(to: url)
    document.reconcileWithDisk()
    XCTAssertEqual(document.indentUnit, 4, "丸ごと置き換えで検出し直す")
    XCTAssertEqual(surface.indentUnit, 4)
  }

  /// 役割の区間は構文層の区間を後勝ちで平らにした、重ならない昇順の列で、窓の中だけを答える（ミニマップの字の色）。
  func testRoleSpansAreFlatNonOverlappingAndInsideTheWindowOnly() throws {
    let text = "// head\nlet a = 1 // tail\n/* block */\n"
    let document = try open("c.swift", text).document
    let all = document.roleSpans(in: NSRange(location: 0, length: text.utf16.count))
    for (previous, next) in zip(all, all.dropFirst()) {
      XCTAssertLessThanOrEqual(NSMaxRange(previous.range), next.range.location, "重ならず昇順")
    }
    XCTAssertEqual(
      all.filter { $0.role == .comment }.map(\.range),
      [
        NSRange(location: 0, length: 7), NSRange(location: 18, length: 7),
        NSRange(location: 26, length: 11),
      ])
    XCTAssertEqual(all.first { $0.role == .keyword }?.range, NSRange(location: 8, length: 3))
    let second = document.roleSpans(in: NSRange(location: 8, length: 18))
    XCTAssertTrue(
      second.allSatisfy { NSLocationInRange($0.range.location, NSRange(location: 8, length: 18)) })
    XCTAssertEqual(
      second.filter { $0.role == .comment }.map(\.range), [NSRange(location: 18, length: 7)])
    let cut = document.roleSpans(in: NSRange(location: 30, length: 4))
    XCTAssertEqual(cut.map(\.range), [NSRange(location: 30, length: 4)], "窓が区間を切れば窓の中だけ")
    let plain = try open("p.txt", "// not a comment\n").document
    XCTAssertEqual(plain.roleSpans(in: NSRange(location: 0, length: 5)), [], "文法が無ければ空")
  }

  /// 本文の通知は構文木の更新の後——通知の中で読む役割の区間が新しい本文を指す。通知は編集と、役割が変わりうる
  /// 区間（構文木の差分）を運ぶ。
  func testTextChangeArrivesAfterTheSyntaxTreeIsUpdatedAndCarriesTheChangedRegion() throws {
    let opened = try open("t.swift", "let a = 1\n")
    let (document, surface) = (opened.document, opened.surface)
    var seen: [[NSRange]] = []
    var changes: [TextChange] = []
    document.onTextChange = { change in
      changes.append(change)
      seen.append(
        document.roleSpans(in: NSRange(location: 0, length: 15)).filter { $0.role == .comment }
          .map(\.range))
    }
    surface.replace(NSRange(location: 0, length: 0), with: "// c\n")
    XCTAssertEqual(seen, [[NSRange(location: 0, length: 4)]])
    XCTAssertEqual(
      changes.map(\.edit), [TextEdit(range: NSRange(location: 0, length: 0), replacementLength: 5)])
    XCTAssertTrue(changes[0].changedRoles.contains(integersIn: 0..<4), "挿した comment の区間は役割が変わった")

    let plainOpened = try open("p.txt", "abc")
    let (plain, plainSurface) = (plainOpened.document, plainOpened.surface)
    var plainChanges: [TextChange] = []
    plain.onTextChange = { plainChanges.append($0) }
    plainSurface.replace(NSRange(location: 1, length: 1), with: "xy")
    XCTAssertEqual(plainChanges.map(\.changedRoles), [IndexSet(integersIn: 1..<3)], "文法が無ければ置換後の区間")
  }

  /// 俯瞰の式が読む「先頭行（小数）」は viewport の行頭オフセットと隠れ割合から、その逆の「この行を先頭に」は整数部の
  /// 行頭と小数部の割合へ分けて面に渡す（行の範囲に収める）。
  func testViewportLinesAndScrollToFirstLineMapBetweenLinesAndOffsets() throws {
    let opened = try open("v.txt", (0..<10).map { "row \($0)\n" }.joined())
    let (document, surface) = (opened.document, opened.surface)
    surface.viewport = TextViewport(
      firstVisible: document.lineIndex.start(ofRow: 3), hiddenFraction: 0.25, visibleLines: 4.5)
    XCTAssertEqual(document.viewportLines.first, 3.25)
    XCTAssertEqual(document.viewportLines.visible, 4.5)

    document.scroll(toFirstLine: 7.75)
    document.scroll(toFirstLine: -3)
    document.scroll(toFirstLine: 99)
    XCTAssertEqual(surface.toppedAt.map(\.offset), [document.lineIndex.start(ofRow: 7), 0, document.lineIndex.length])
    XCTAssertEqual(surface.toppedAt.map(\.hiddenFraction), [0.75, 0, 0], "先頭の前・最終行の先は端に収める")
  }

  /// 選択の先頭の語は、その行の本文（改行を除く）から、長い行ならキャレットの前後の窓だけを読んで探す。
  func testWordAtTheSelectionReadsTheLineOrItsWindow() throws {
    let long = String(repeating: "a", count: 400) + " " + String(repeating: "b", count: 1500)
    let opened = try open("w.txt", "x yy\r\n" + long + "\n")
    let document = opened.document
    XCTAssertEqual(document.word(at: NSRange(location: 3, length: 0)), NSRange(location: 2, length: 2))
    XCTAssertEqual(
      document.word(at: NSRange(location: 4, length: 0)), NSRange(location: 2, length: 2),
      "行末（CRLF の手前）で語の末尾に接する")
    let lineStart = document.lineIndex.start(ofRow: 1)
    XCTAssertEqual(
      document.word(at: NSRange(location: lineStart + 1800, length: 0)),
      NSRange(location: lineStart + 1300, length: 601), "窓（前 500）の端で切れる")
  }

  func testSelectionAndViewportChangesAreForwarded() throws {
    let opened = try open("s.txt", "abc")
    let (document, surface) = (opened.document, opened.surface)
    var selections = 0
    var viewports = 0
    document.onSelectionChange = { selections += 1 }
    document.onViewportChange = { viewports += 1 }
    surface.selectedRange = NSRange(location: 1, length: 1)
    surface.delegate?.surfaceDidChangeViewport(surface)
    XCTAssertEqual(selections, 1)
    XCTAssertEqual(viewports, 1)
  }
}
