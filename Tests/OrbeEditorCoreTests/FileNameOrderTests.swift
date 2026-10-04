import Foundation
import XCTest

@testable import OrbeEditorCore

/// ファイル名の比べ方（大小とアクセントを無視し数を数として比べる。同じと見たものは字の並びで決める）と、それを区切りごとに
/// 使うパスの順序（同じ階層ではファイルが先）。エクスプローラーと検索結果が共有する。
///
/// 壊れると何が起きるか。`file10` が `file2` より前に来る。エクスプローラーと検索結果で同じフォルダの並びが食い違う。
/// 大小だけ違う名前の順が実行ごとに揺れる。検索結果でサブフォルダのファイルが同じ階層のファイルの間に割り込む。
final class FileNameOrderTests: XCTestCase {
  private func sorted(_ names: [String]) -> [String] {
    names.sorted(by: FileNameOrder.precedes)
  }

  func testNumbersCompareAsNumbersAndCaseAndAccentsAreIgnored() {
    XCTAssertEqual(sorted(["file10", "file2", "File1"]), ["File1", "file2", "file10"])
    XCTAssertEqual(sorted(["b", "Äpfel", "a"]), ["a", "Äpfel", "b"])
  }

  /// 大小・ゼロ詰めだけが違う名前も同じとは見ず、順は向きに依らず 1 つに決まる。
  func testNamesThatLookTheSameStillHaveAFixedOrder() {
    for (a, b) in [("a", "A"), ("foo1", "foo01")] {
      let forward = FileNameOrder.compare(a, b)
      XCTAssertNotEqual(forward, .orderedSame, "\(a) / \(b)")
      XCTAssertEqual(FileNameOrder.compare(b, a).rawValue, -forward.rawValue, "\(a) / \(b)")
    }
  }

  private func sortedPaths(_ paths: [String]) -> [String] {
    paths.map { ($0, FileNameOrder.PathKey($0)) }
      .sorted { FileNameOrder.comparePaths($0.1, $1.1) == .orderedAscending }
      .map(\.0)
  }

  /// パスは区切りごとに名前で比べ、同じ階層ではファイルが先。
  func testPathsCompareByComponentWithFilesBeforeFolders() {
    XCTAssertEqual(
      sortedPaths([
        "src/b.swift", "z.txt", "src/a/x.swift", "a-b/y", "a/y", "src/a10.swift", "src/a2.swift",
      ]),
      ["z.txt", "a/y", "a-b/y", "src/a2.swift", "src/a10.swift", "src/b.swift", "src/a/x.swift"])
  }
}
