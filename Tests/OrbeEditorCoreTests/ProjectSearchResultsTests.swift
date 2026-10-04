import Foundation
import XCTest

@testable import OrbeEditorCore

/// 検索結果の積み上げ——まとまりはパスの順、同じパスは 1 つ（置き直せば置き換わり、一致 0 なら消える）、一致の総数は
/// 20000 で打ち切る（はみ出したまとまりは一致も区間も削る）。開いている文書のまとまりは編集に合わせて区間をずらし、ディスクの
/// まとまりは開いた文書の区間に直せる。
///
/// 壊れると何が起きるか。結果の並びが届いた順に揺れる。同じファイルが二重に出る。上限を越えて集め main が詰まる、上限で
/// 削った一致と地の区間が食い違う。編集の後に地が字からずれる。
final class ProjectSearchResultsTests: XCTestCase {
  private func match(line: Int, column: Int, length: Int = 1) -> SearchMatch {
    SearchMatch(
      line: line, column: NSRange(location: column, length: length),
      preview: SearchPreview(before: "", match: "", after: ""))
  }

  private func disk(_ path: String, _ count: Int) -> SearchFileMatches {
    SearchFileMatches(path: path, matches: (0..<count).map { match(line: $0, column: 0) })
  }

  private func document(_ path: String, _ ranges: [NSRange], version: Int = 1)
    -> SearchFileMatches
  {
    SearchFileMatches(
      path: path, matches: ranges.map { match(line: 0, column: $0.location, length: $0.length) },
      document: .init(ranges: ranges, version: version))
  }

  func testFilesAreKeptInPathOrderOnePerPath() {
    var results = ProjectSearchResults()
    for file in [disk("src/b.txt", 1), disk("a10.txt", 1), disk("a2.txt", 2), disk("src/a/x", 1)] {
      results.set(file)
    }
    XCTAssertEqual(results.files.map(\.path), ["a2.txt", "a10.txt", "src/b.txt", "src/a/x"])
    XCTAssertEqual(results.total, 5)

    results.set(disk("a2.txt", 3))
    XCTAssertEqual(results.files.map(\.path), ["a2.txt", "a10.txt", "src/b.txt", "src/a/x"])
    XCTAssertEqual(results["a2.txt"]?.count, 3, "同じパスは置き換わる")
    XCTAssertEqual(results.total, 6)

    results.set(disk("a10.txt", 0))
    XCTAssertEqual(results.files.map(\.path), ["a2.txt", "src/b.txt", "src/a/x"], "一致 0 なら消える")
    XCTAssertEqual(results.total, 5)
    XCTAssertNil(results.index(of: "a10.txt"))
  }

  /// 並んだ列を一度に置くのは、1 つずつ置くのと同じ結果になる（置き換え・除去を含む）。
  func testSettingASortedBatchEqualsSettingOneByOne() {
    var base = ProjectSearchResults()
    for file in [disk("b", 1), disk("d", 2), disk("f", 1)] { base.set(file) }
    let batch = [disk("a", 1), disk("b", 3), disk("d", 0), disk("e", 1), disk("g", 2)]

    var oneByOne = base
    for file in batch { oneByOne.set(file) }
    var together = base
    together.set(sorted: batch)
    XCTAssertEqual(together, oneByOne)
    XCTAssertEqual(together.files.map(\.path), ["a", "b", "e", "f", "g"])
  }

  /// 総数は上限で止まり、はみ出したまとまりは一致も文書の区間も削る。ちょうど上限でも打ち切りとして見せる。
  func testTheTotalStopsAtTheLimitTrimmingTheOverflowingFile() {
    var results = ProjectSearchResults()
    results.set(disk("a", ProjectSearchResults.limit - 2))
    XCTAssertFalse(results.isLimited)
    let ranges = (0..<5).map { NSRange(location: $0 * 2, length: 1) }
    results.set(document("b", ranges))
    XCTAssertTrue(results.isLimited)
    XCTAssertEqual(results.total, ProjectSearchResults.limit)
    XCTAssertEqual(results["b"]?.count, 2)
    XCTAssertEqual(results["b"]?.document?.ranges, Array(ranges.prefix(2)))

    results.set(disk("c", 1))
    XCTAssertNil(results["c"], "上限の後は置かない")

    var exact = ProjectSearchResults()
    exact.set(disk("a", ProjectSearchResults.limit))
    XCTAssertTrue(exact.isLimited, "ちょうど上限も打ち切り（その先を探していない）")
  }

  /// 開いている文書のまとまりは編集に合わせて区間をずらし（掛かった一致は落とす）、版を進める。
  func testTrackingAnEditShiftsTheDocumentRangesAndDropsTouchedOnes() {
    var results = ProjectSearchResults()
    results.set(
      document(
        "a",
        [
          NSRange(location: 0, length: 3), NSRange(location: 10, length: 3),
          NSRange(location: 20, length: 3),
        ]))
    results.track(
      "a", [EditSweep([TextEdit(range: NSRange(location: 11, length: 1), replacement: "xyz")])],
      version: 2)
    XCTAssertEqual(
      results["a"]?.document,
      .init(
        ranges: [NSRange(location: 0, length: 3), NSRange(location: 22, length: 3)], version: 2))
    XCTAssertEqual(results["a"]?.count, 2)
    XCTAssertEqual(results.total, 2)

    results.track(
      "a", [EditSweep([TextEdit(range: NSRange(location: 0, length: 25), replacement: "")])],
      version: 3)
    XCTAssertNil(results["a"], "一致が無くなれば消える")
    XCTAssertEqual(results.total, 0)
  }

  /// ディスクのまとまりを開いた文書に直す: 行頭 ＋ 行の中の位置。本文の行に収まらない一致は落とす。
  func testAttachingADiskFileMapsLinesToDocumentRanges() {
    var results = ProjectSearchResults()
    results.set(
      SearchFileMatches(
        path: "a",
        matches: [
          match(line: 0, column: 1, length: 2), match(line: 2, column: 0, length: 3),
          match(line: 2, column: 5, length: 3), match(line: 9, column: 0),
        ]))
    results.attach("a", to: TextRope("xab\n\nfoo bar"), version: 7)
    XCTAssertEqual(
      results["a"]?.document,
      .init(
        ranges: [NSRange(location: 1, length: 2), NSRange(location: 5, length: 3)], version: 7))
    XCTAssertEqual(results.total, 2)
  }

  /// 区間の字は探した字（プレビューの一致）と照合する。ディスクのまとまりを直すとき・開いている文書のまとまりを見せるとき、
  /// 字の違う一致は落とし、長くて頭だけを持つ一致は頭で照合する。壊れると、探した後にファイルが変わったとき無関係な字を
  /// 一致として選ぶ。
  func testMatchesWhoseTextNoLongerAgreesAreDropped() {
    let found = { (line: Int, column: Int, text: String) in
      SearchMatch(
        line: line, column: NSRange(location: column, length: text.utf16.count),
        preview: SearchPreview(
          line: text as NSString, match: NSRange(location: 0, length: text.utf16.count)))
    }
    let long = String(repeating: "n", count: 300)
    var results = ProjectSearchResults()
    results.set(
      SearchFileMatches(
        path: "a", matches: [found(0, 0, "needle"), found(0, 9, "needle"), found(1, 0, long)]))
    let dropped = results.attach("a", to: TextRope("needle a zzzzzz\n" + long + "\n"), version: 0)
    XCTAssertTrue(dropped)
    XCTAssertEqual(
      results["a"]?.document?.ranges,
      [NSRange(location: 0, length: 6), NSRange(location: 16, length: 300)], "長い一致は頭で照合する")
    XCTAssertEqual(results.total, 2)

    XCTAssertFalse(results.dropDisagreeing("a", with: TextRope("needle a zzzzzz\n" + long + "\n")))
    XCTAssertTrue(results.dropDisagreeing("a", with: TextRope("xxxxxx a zzzzzz\n" + long + "\n")))
    XCTAssertEqual(results["a"]?.document?.ranges, [NSRange(location: 16, length: 300)])
    XCTAssertEqual(results.total, 1)
  }
}
