import Foundation
import XCTest

@testable import OrbeEditorCore

/// 文書と裏の仕事の結び目——裏の結果は届いた時機に依らず今の本文の上に置かれ、作り直しの途中で色が素へ戻らず、main が
/// 色を待つのは初めて見せるときの上限までだけ。
///
/// 壊れると何が起きるか。打鍵の直後に色・git の印・検索の地が字からずれて見える。大きな変更の後に文書の広い範囲の色が
/// 一度消えてから付き直す。復元で文書を開くたびに main が止まる、タブを切り替えるたびに固まる。
@MainActor
final class EditorDocumentBackgroundTests: XCTestCase {
  private let registry = LanguageRegistry(queriesRoot: Queries.root)
  private var root: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-background-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
    try super.tearDownWithError()
  }

  private func open(_ name: String, _ text: String) throws -> (EditorDocument, FakeTextSurface) {
    let url = root.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    let contents = try EditorDocument.read(url)
    let surface = FakeTextSurface(text: contents.text)
    return (
      EditorDocument(url: url, contents: contents, surface: surface, registry: registry), surface
    )
  }

  // MARK: - 古い版の結果

  /// 問いを頼んでから結果が届くまでに本文が変われば、結果はその後の編集に合わせてずらして届く——編集より後ろの一致は
  /// 動いた字に付いていき、編集に掛かった一致は落ちる。
  func testAnAnswerReachesTheTextAsEditedAfterItWasAsked() throws {
    let (document, surface) = try open("q.txt", "ab x ab x ab\n")
    var answers: [[NSRange]] = []
    document.onAnalysis = { _, ranges in answers.append(ranges) }

    document.analyze(.find("ab"))
    surface.replace(NSRange(location: 0, length: 0), with: "zz\n")
    surface.replace(NSRange(location: 9, length: 1), with: "")
    XCTAssertEqual(surface.text, "zz\nab x a x ab\n", "前提")
    XCTAssertTrue(document.waitUntilCaughtUp())

    XCTAssertEqual(
      answers, [[NSRange(location: 3, length: 2), NSRange(location: 12, length: 2)]],
      "頼んだときの一致（0・5・10）を 2 回の編集でずらし、消した字に掛かる一致は落とす")
  }

  /// 裏が打鍵に遅れて、前の版の構文・行差分の結果が後から届いても、今の本文の上へずらして置く——届いた時機に依らず、
  /// 役割の並びは本文と同じ長さで編集していない字は自分の役割を保ち、git の印は動いた行に付いていく。
  func testResultsOfAnOlderVersionAreShiftedOntoTheCurrentText() throws {
    let lines = (0..<3000).map { "const Foo\($0) = new Bar(\"x\"); // Baz\n" }
    let starts = lines.reduce(into: [0]) { $0.append($0.last! + $1.utf16.count) }
    let changedRow = 60
    var baseline = lines
    baseline[changedRow] = lines[changedRow].replacingOccurrences(of: "Baz", with: "Qux")
    let (document, surface) = try open("o.js", lines.joined())
    document.baseline = baseline.joined()
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30))
    let keyword = document.roles.roles(in: NSRange(location: 0, length: 5)).first?.role
    XCTAssertNotNil(keyword, "前提: const に色が付いている")

    let marker = "/**/\n"
    for inserted in 1...40 {
      surface.replace(NSRange(location: 0, length: 0), with: marker)
      // 裏の結果を待ち切らずに次を打つ——前の版の結果が、後の編集が済んだ本文へ届く。
      _ = document.waitUntilCaughtUp(timeout: 0.001)
      let head = inserted * marker.utf16.count
      let misplaced = stride(from: 0, to: lines.count, by: 97).filter { row in
        document.roles.roles(in: NSRange(location: head + starts[row], length: 5)).map(\.role)
          != [keyword].compactMap { $0 }
      }
      let modified = document.hunks.filter { $0.oldCount > 0 && $0.newCount > 0 }.map(\.newStart)
      XCTAssertEqual(document.roles.length, document.text.length, "\(inserted) 回目: 役割の並びは本文を覆う")
      XCTAssertEqual(misplaced, [], "\(inserted) 回目: const の役割がずれた行")
      XCTAssertEqual(modified, [changedRow + 1 + inserted], "\(inserted) 回目: 変更の印は動いた行")
      guard document.roles.length == document.text.length, misplaced.isEmpty,
        modified == [changedRow + 1 + inserted]
      else { return }
    }
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30))
  }

  // MARK: - 作り直しの途中

  /// 文書全体の構文が変わる編集の後、裏が見えている範囲から順に作り直している途中でも、編集の前も後も役割のある字が
  /// 役割なし（素の色）で届くことはない——作り直すまでは前の役割のまま。
  func testColoredTextDoesNotTurnPlainWhileTheBackgroundRebuilds() throws {
    let body = String(repeating: "const Foo = new Bar(\"x\"); // Baz\n", count: 3000)
    let source = "x = `\n" + body + "`;\n"
    let (document, surface) = try open("t.js", source)
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30))
    let tick = 4
    XCTAssertEqual(surface.substring(in: NSRange(location: tick, length: 1)), "`", "前提")
    var before = perUnit(document)
    let template = (tick + 1)..<(source.utf16.count - 2)
    XCTAssertTrue(before[template].allSatisfy { $0 != nil }, "前提: テンプレート文字列の中は全部色付き")
    before.remove(at: tick)
    var delivered: [[SyntaxRole?]] = []
    document.onRolesChange = { _ in delivered.append(self.perUnit(document)) }

    surface.replace(NSRange(location: tick, length: 1), with: "")
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30))

    let after = perUnit(document)
    XCTAssertGreaterThan(delivered.count, 1, "前提: 作り直しの途中の結果が届いた")
    for (index, roles) in delivered.enumerated() {
      let plain = roles.indices.first { roles[$0] == nil && before[$0] != nil && after[$0] != nil }
      XCTAssertNil(plain, "\(index) 回目に届いた役割で、色のある字が素に戻った")
    }
  }

  /// 字ごとの役割（本文全体）。
  private func perUnit(_ document: EditorDocument) -> [SyntaxRole?] {
    var result = [SyntaxRole?](repeating: nil, count: document.text.length)
    for span in document.roles.roles(in: NSRange(location: 0, length: document.text.length)) {
      for offset in span.range.location..<NSMaxRange(span.range) { result[offset] = span.role }
    }
    return result
  }

  // MARK: - 初めて見せるとき

  /// 開くだけでは色を待たない（再起動の復元で見えていない文書を開いても main は止まらない）。初めて見せるときは、色が
  /// 届くのを上限まで待つ——色が付いて出るか、上限まで待ったかのどちらか。2 回目に見せるときは待たない。
  func testOnlyTheFirstShowWaitsForColorsAndOnlyUpToTheLimit() throws {
    let (document, surface) = try open("p.swift", "let a = 1\n")
    let all = NSRange(location: 0, length: document.text.length)
    XCTAssertEqual(document.roles.roles(in: all), [], "開くだけでは待たない")

    let started = Date()
    document.prepareToShow()
    let waited = Date().timeIntervalSince(started)
    XCTAssertTrue(
      !document.roles.roles(in: all).isEmpty || waited >= EditorDocument.firstColorsWait,
      "初めて見せるときは色を待つ（\(waited) 秒で色が無いまま戻った）")

    XCTAssertTrue(document.waitUntilCaughtUp())
    surface.replace(NSRange(location: 0, length: 0), with: "// ")
    document.prepareToShow()
    XCTAssertEqual(
      document.roles.roles(in: NSRange(location: 3, length: 3)).map(\.role), [.keyword],
      "2 回目は待たない（裏の comment を受け取らず、ずらした前の色のまま）")
  }
}
