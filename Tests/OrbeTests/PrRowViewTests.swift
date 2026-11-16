import AppKit
import XCTest

@testable import Orbe

/// PR のパネルの行——字は中身の同一性が変わったときだけ組み、描く事実（確認済みの数・ツリーかリストか・言語）のどれが
/// 変わっても組み直す。
///
/// 壊れると何が起きるか: チェックを押しても行の印や「N/M 確認済み」が前の数のまま。言語を切り替えても見出しが前の言語の
/// まま。リストにしてもファイルの行にディレクトリが出ない。
@MainActor
final class PrRowViewTests: OrbeTestCase {
  private func viewedHeader(_ viewed: Int, of count: Int, _ language: Language) -> String {
    L10n.string(.editorPrFiles, language) + ", "
      + L10n.format(.editorPrViewedCount, language, viewed, count)
  }

  private func check(_ view: PrRowView) -> PrRowView.Check? {
    switch view.content {
    case .folder(let folder)?: folder.check
    case .file(let file)?: file.check
    default: nil
    }
  }

  /// 変更ファイルの見出しは、確認済みの数・言語・ツリーかリストかのどれが変わっても組み直す。
  func testTheFilesHeaderIsRebuiltWhenAFactItShowsChanges() {
    let view = PrRowView(frame: .zero)
    let header = PrLayout.Item.section(.files, isOpen: true, count: 3)
    view.show(header, facts: .init(viewed: 1, asTree: true), language: .ja, emoji: nil)
    XCTAssertEqual(view.accessibilityLabel(), viewedHeader(1, of: 3, .ja))

    view.show(header, facts: .init(viewed: 2, asTree: true), language: .ja, emoji: nil)
    XCTAssertEqual(view.accessibilityLabel(), viewedHeader(2, of: 3, .ja), "確認済みの数")
    view.show(header, facts: .init(viewed: 2, asTree: true), language: .en, emoji: nil)
    XCTAssertEqual(view.accessibilityLabel(), viewedHeader(2, of: 3, .en), "言語")
    view.show(header, facts: .init(viewed: 2, asTree: false), language: .en, emoji: nil)
    guard case .section(let section)? = view.content else { return XCTFail("見出し") }
    XCTAssertEqual(section.asTree, false, "ツリーかリストか")
  }

  /// フォルダとファイルの行は、確認済みが変わればチェックの姿を組み直す。ファイルの行は、リストにすればディレクトリを出す。
  func testFolderAndFileRowsAreRebuiltWhenTheirViewedOrViewChanges() {
    let view = PrRowView(frame: .zero)
    let folder = PrLayout.Item.folder(
      path: "src", depth: 0, isOpen: true, files: ["src/a", "src/b"])
    view.show(folder, facts: .init(viewed: 1, asTree: true), language: .ja, emoji: nil)
    XCTAssertEqual(check(view), .partial)
    view.show(folder, facts: .init(viewed: 2, asTree: true), language: .ja, emoji: nil)
    XCTAssertEqual(check(view), .on, "配下が全部確認済み")

    let file = PrLayout.Item.file(path: "src/a", change: .modified, depth: 1)
    view.show(file, facts: .init(viewed: 0, asTree: true), language: .ja, emoji: nil)
    XCTAssertEqual(check(view), .off)
    view.show(file, facts: .init(viewed: 1, asTree: true), language: .ja, emoji: nil)
    XCTAssertEqual(check(view), .on, "確認済みにした")
    view.show(file, facts: .init(viewed: 1, asTree: false), language: .ja, emoji: nil)
    guard case .file(let row)? = view.content else { return XCTFail("ファイルの行") }
    XCTAssertNotNil(row.directory, "リストならディレクトリを出す")
  }

  /// 変更ファイルの見出しは、ファイルの数と確認済みの数の組が違えば組み直す（並べた数字が同じ組でも）。
  func testTheFilesHeaderTellsTheFileCountAndTheViewedCountApart() {
    let view = PrRowView(frame: .zero)
    view.show(
      .section(.files, isOpen: true, count: 12), facts: .init(viewed: 10, asTree: true),
      language: .ja, emoji: nil)
    view.show(
      .section(.files, isOpen: true, count: 121), facts: .init(viewed: 0, asTree: true),
      language: .ja, emoji: nil)
    XCTAssertEqual(view.accessibilityLabel(), viewedHeader(0, of: 121, .ja))
  }
}
