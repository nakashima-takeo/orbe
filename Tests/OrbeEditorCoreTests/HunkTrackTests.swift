import Foundation
import OrbeTestSupport
import XCTest

@testable import OrbeEditorCore

/// 編集でずらしたハンク（裏の結果が届く前）が、底と今の本文の正しい対応であること。壊れると並列の diff が precondition
/// で落ちる・ガターや diff の並びが本文の外や違う行を指す。
@MainActor
final class HunkTrackTests: XCTestCase {
  private func opened(_ text: String, base: String) throws -> (EditorDocument, FakeTextSurface) {
    let dir = TestScratch.caseDir
      .appendingPathComponent("orbe-track-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("a.txt")
    try Data(text.utf8).write(to: url)
    let surface = FakeTextSurface(text: text)
    let document = EditorDocument(
      url: url, contents: try EditorDocument.read(url), surface: surface,
      registry: LanguageRegistry(queriesRoot: Queries.root))
    document.baseline = base
    XCTAssertTrue(document.waitUntilCaughtUp())
    return (document, surface)
  }

  private func lines(_ text: String) -> [Substring] {
    text.split(separator: "\n", omittingEmptySubsequences: false)
  }

  /// `LineDiff` の出力と同じ形か: 昇順・重ならない（間に文脈を挟む）・両側とも本文の中・区間の外の行は両側で 1 対 1 で
  /// 同じ中身（`contents` が false なら中身は見ない——行の数を変えない編集は、届くまで区間を変えない）。
  private func assertShape(
    _ hunks: [LineHunk], base: String, text: String, contents: Bool = true, _ context: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let (old, new) = (lines(base), lines(text))
    var (oldNext, newNext) = (0, 0)
    for (index, hunk) in hunks.enumerated() {
      let (o, n) = (hunk.oldLines, hunk.newLines)
      if index > 0 {
        XCTAssertGreaterThan(n.lowerBound, newNext, "区間の間に文脈を挟む: \(context)", file: file, line: line)
      }
      XCTAssertEqual(
        o.lowerBound - oldNext, n.lowerBound - newNext, "区間の外は 1 対 1: \(context)", file: file,
        line: line)
      XCTAssertLessThanOrEqual(o.upperBound, old.count, "古い側は本文の中: \(context)", file: file, line: line)
      XCTAssertLessThanOrEqual(n.upperBound, new.count, "新しい側は本文の中: \(context)", file: file, line: line)
      guard o.lowerBound >= oldNext, n.lowerBound >= newNext else { return }
      if contents {
        for k in 0..<min(o.lowerBound - oldNext, n.lowerBound - newNext) {
          XCTAssertEqual(old[oldNext + k], new[newNext + k], "文脈の行は同じ中身: \(context)", file: file, line: line)
        }
      }
      (oldNext, newNext) = (o.upperBound, n.upperBound)
    }
    XCTAssertEqual(old.count - oldNext, new.count - newNext, "末尾の文脈は 1 対 1: \(context)", file: file, line: line)
    guard contents, old.count - oldNext == new.count - newNext, oldNext <= old.count else { return }
    for k in 0..<(old.count - oldNext) {
      XCTAssertEqual(old[oldNext + k], new[newNext + k], "文脈の行は同じ中身: \(context)", file: file, line: line)
    }
  }

  /// 行数を変えながら 2 つの区間をまたぐ外の書き換え（差し替えは 1 つの縮めた編集になる）。
  func testAReplacementSpanningTwoHunksKeepsTheShape() throws {
    let base = "a\nb\nc\nd\ne\nf\ng\nh\n"
    let (document, surface) = try opened("a\nb\nC\nd\nE\nf\ng\nh\n", base: base)
    XCTAssertEqual(document.hunks.count, 2)
    let next = "a\nX\nC\nd\nE\nf\nY\nY2\nh\n"
    surface.replaceAll(with: next)
    assertShape(document.hunks, base: base, text: next, "2 区間をまたぐ")
    XCTAssertEqual(document.hunks, [LineHunk(oldStart: 2, oldCount: 6, newStart: 2, newCount: 7)])
  }

  /// 最後の行の途中から末尾まで消す外の書き換え。
  func testCuttingTheLastLinesFromTheMiddleOfALineKeepsTheShape() throws {
    let base = "a\nb\nX\nY"
    let (document, surface) = try opened("a\nb\nc", base: base)
    surface.replaceAll(with: "a\nb")
    assertShape(document.hunks, base: base, text: "a\nb", "行の途中から末尾まで")

    let longBase = (0..<10).map(String.init).joined(separator: "\n")
    let (other, otherSurface) = try opened(
      (0..<9).map(String.init).joined(separator: "\n"), base: longBase)
    otherSurface.replaceAll(with: "0\n1\n2\n3\n4\n5")
    assertShape(other.hunks, base: longBase, text: "0\n1\n2\n3\n4\n5", "末尾を縮める")
  }

  /// 行末の Enter・行ごとの挿入と削除は、変えていない行を区間に入れない（届く結果と同じ印）。行の中の Enter は、割った
  /// 行を変更に入れる。
  func testLineBreaksAtTheEndOfALineAddOnlyTheNewRow() throws {
    let base = "a\nbc\n"
    let (document, surface) = try opened(base, base: base)
    surface.replace(NSRange(location: 1, length: 0), with: "\n")
    XCTAssertEqual(document.hunks, [LineHunk(oldStart: 1, oldCount: 0, newStart: 2, newCount: 1)], "行末の Enter は追加 1 行")
    XCTAssertTrue(document.waitUntilCaughtUp())
    let arrived = document.hunks
    surface.replace(NSRange(location: 1, length: 1), with: "")
    XCTAssertEqual(document.hunks, [], "足した改行を消せば、区間は無くなる")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(arrived, [LineHunk(oldStart: 1, oldCount: 0, newStart: 2, newCount: 1)], "届く結果と同じ")

    surface.replace(NSRange(location: 2, length: 0), with: "x\ny\n")
    XCTAssertEqual(
      document.hunks, [LineHunk(oldStart: 1, oldCount: 0, newStart: 2, newCount: 2)], "行頭から行頭は行ごとの追加")
    XCTAssertTrue(document.waitUntilCaughtUp())
    surface.replace(NSRange(location: 2, length: 4), with: "")
    XCTAssertEqual(document.hunks, [], "行ごとの削除")
    XCTAssertTrue(document.waitUntilCaughtUp())

    surface.replace(NSRange(location: 3, length: 0), with: "\n")
    XCTAssertEqual(
      document.hunks, [LineHunk(oldStart: 2, oldCount: 1, newStart: 2, newCount: 2)], "bc の中の Enter は bc の変更")
    assertShape(document.hunks, base: base, text: surface.text, "行の中の Enter")
  }

  /// 乱数の編集の列（届く前に重ねる）で、ずらしたハンクがいつでも正しい対応の形を保つ。中身の対応は、届いてから行の数を
  /// 変えない編集が無い間だけ見る。
  func testRandomEditsKeepTheHunksAValidCorrespondence() throws {
    var random = SeededRandom(seed: 0x5eed)
    let pieces = ["a", "b", "\n", "\n", "ab\n", "\nb", ""]
    func text(_ count: Int) -> String {
      (0..<count).map { _ in pieces[random.next(below: pieces.count)] }.joined()
    }
    for round in 0..<200 {
      let base = text(random.next(below: 12))
      let (document, surface) = try opened(text(random.next(below: 12)), base: base)
      var exact = true
      for step in 0..<8 {
        let length = surface.length
        let location = random.next(below: length + 1)
        let range = NSRange(location: location, length: random.next(below: length - location + 1))
        let replacement = text(random.next(below: 3))
        let breaks = { (string: String) in string.filter { $0 == "\n" }.count }
        if breaks(surface.substring(in: range)) == breaks(replacement) { exact = false }
        surface.replace(range, with: replacement)
        assertShape(
          document.hunks, base: base, text: surface.text, contents: exact, "回 \(round) の \(step)")
      }
      XCTAssertTrue(document.waitUntilCaughtUp())
      assertShape(document.hunks, base: base, text: surface.text, "回 \(round) の届いた結果")
    }
  }
}

/// 決まった列を返す乱数（xorshift）。
private struct SeededRandom {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next(below bound: Int) -> Int {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return Int(state % UInt64(max(bound, 1)))
  }
}
