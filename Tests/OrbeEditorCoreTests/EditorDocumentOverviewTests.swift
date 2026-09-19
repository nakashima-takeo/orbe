import Foundation
import XCTest

@testable import OrbeEditorCore

/// 文書が俯瞰と検索へ出す口——インデント単位は文書が検出して面へ押す（開いたとき・丸ごと置き換え）、comment 区間は
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

  func testCommentRangesAnswerTheCommentRoleInsideTheWindowOnly() throws {
    let text = "// head\nlet a = 1 // tail\n/* block */\n"
    let document = try open("c.swift", text).document
    let all = document.commentRanges(in: NSRange(location: 0, length: text.utf16.count))
    XCTAssertEqual(all.map(\.location), [0, 18, 26])
    let second = document.commentRanges(in: NSRange(location: 8, length: 18))
    XCTAssertEqual(second.count, 1)
    XCTAssertEqual(second[0].location, 18, "窓の外の comment は答えない")
    let plain = try open("p.txt", "// not a comment\n").document
    XCTAssertEqual(plain.commentRanges(in: NSRange(location: 0, length: 5)), [], "文法が無ければ空")
  }

  /// 本文の通知は構文木の更新の後——通知の中で読む comment 区間が新しい本文を指す。通知は編集と、役割が変わりうる
  /// 区間（構文木の差分）を運ぶ。
  func testTextChangeArrivesAfterTheSyntaxTreeIsUpdatedAndCarriesTheChangedRegion() throws {
    let opened = try open("t.swift", "let a = 1\n")
    let (document, surface) = (opened.document, opened.surface)
    var seen: [[NSRange]] = []
    var changes: [TextChange] = []
    document.onTextChange = { change in
      changes.append(change)
      seen.append(document.commentRanges(in: NSRange(location: 0, length: 20)))
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

  func testSelectionAndViewportChangesAreForwarded() throws {
    let opened = try open("s.txt", "abc")
    let (document, surface) = (opened.document, opened.surface)
    var selections = 0
    var viewports = 0
    document.onSelectionChange = { selections += 1 }
    document.onViewportChange = { viewports += 1 }
    surface.selectedRange = NSRange(location: 1, length: 1)
    surface.delegate?.surfaceDidScroll(surface)
    XCTAssertEqual(selections, 1)
    XCTAssertEqual(viewports, 1)
  }
}
