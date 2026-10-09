import Foundation
import OrbeTestSupport
import XCTest
import os

@testable import OrbeEditorCore

/// 文書と裏の仕事の結び目——裏の結果は届いた時機に依らず今の本文の上に置かれ、作り直しの途中で色が素へ戻らず、main が
/// 色を待つのは初めて見せるときの上限までだけ。
///
/// 壊れると何が起きるか。打鍵の直後に色・git の印・検索の地が字からずれて見える。大きな変更の後に文書の広い範囲の色が
/// 一度消えてから付き直す。復元で文書を開くたびに main が止まる、タブを切り替えるたびに固まる。
@MainActor
final class EditorDocumentBackgroundTests: XCTestCase {
  private let registry = LanguageRegistry(queriesRoot: Queries.root)
  private func open(
    _ name: String, _ text: String, quietDelay: DispatchTimeInterval = SyntaxWorker.quietDelay
  ) throws -> (EditorDocument, FakeTextSurface) {
    let url = TestScratch.caseDir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    let contents = try EditorDocument.read(url)
    let surface = FakeTextSurface(text: contents.text)
    return (
      EditorDocument(
        url: url, contents: contents, surface: surface, registry: registry, quietDelay: quietDelay),
      surface
    )
  }

  // MARK: - 古い版の結果

  /// 行差分の上限は文書が受け取る値で、変えると裏へ頼み直し、既定（ガター）では 1 区間に畳む大きな書き換えも行ごとの区間に
  /// なる。上限を戻せば畳んだ区間に戻る。ハンクが今の底に対する結果かは、底を置き直したときだけ届くまで偽になる。
  func testTheHunkLimitIsTheDocumentsAndRequestsAgain() throws {
    let n = LineDiff.maximumComparedLines
    let old = (0..<n).map { "old \($0)\n" }.joined()
    let new = (0..<n).map { $0 % 100 == 0 ? "new \($0)\n" : "old \($0)\n" }.joined()
    let (document, _) = try open("big.txt", new)
    document.baseline = old
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(document.hunks.count, 1, "前提: 既定の上限では 1 区間に畳む")
    var notified = 0
    document.onHunksChange = { notified += 1 }
    document.hunkLimit = .edits(n)
    XCTAssertEqual(document.hunksBase, old, "上限だけを変えた間は、前の上限の結果のまま今の底のハンク")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(document.hunks.count, n / 100, "変えた上限で行ごとに取り直す")
    XCTAssertGreaterThan(notified, 0, "結果が届けば知らせる")
    document.baseline = old + "tail\n"
    XCTAssertEqual(document.hunksBase, old, "底を変えたら、届くまで前の底とそのハンク")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(document.hunksBase, old + "tail\n")
    document.baseline = old
    document.hunkLimit = LineDiff.gutter
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(document.hunks.count, 1)
  }

  /// 同じ上限を置き直しても頼み直さない——見え方を載せ直すたびに上限を押す呼び手が、届いた結果の知らせでまた載せ直しても、
  /// 裏の行差分が回り続けない。
  func testSettingTheSameHunkLimitAgainRequestsNothing() throws {
    let (document, _) = try open("same.txt", "a\nb\n")
    document.baseline = "a\n"
    document.hunkLimit = .edits(10)
    XCTAssertTrue(document.waitUntilCaughtUp())
    var notified = 0
    document.onHunksChange = { notified += 1 }
    document.hunkLimit = .edits(10)
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(notified, 0, "同じ上限では結果が届かない")
  }

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
    let pulled = surface.pulled.count

    surface.replace(NSRange(location: tick, length: 1), with: "")
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30))

    let delivered = surface.pulled.dropFirst(pulled).map { perUnit($0.content.roles) }
    let after = perUnit(document)
    XCTAssertGreaterThan(delivered.count, 1, "前提: 作り直しの途中の結果が届いた")
    for (index, roles) in delivered.enumerated() {
      let plain = roles.indices.first { roles[$0] == nil && before[$0] != nil && after[$0] != nil }
      XCTAssertNil(plain, "\(index) 回目に届いた役割で、色のある字が素に戻った")
    }
  }

  // MARK: - 構文の層の出入り

  /// 注入の層の出入り（フェンスに言語名を書き足す・替える、束ねた層の部分が消える）の後、裏の仕事は層の中身の行まで
  /// 作り直す——作り直す範囲は編集の行だけでなく、出入りした層・構文の変わった層の範囲（編集から離れた行も）に及ぶ。
  func testInjectionLayersComingAndGoingAreRebuilt() throws {
    let markdown = "# T\n\n```\ndef f(x):\n    return 1\n```\n\n```js\nconst Foo = 1; // c\n```\n"
    let tagged =
      "const b = html`<style>p { color: blue; }</style><script>let y = 1;</script>`;\nlet z = 2;\n"
    let split =
      "const a = html`<style>`;\nconst b = 1;\nconst c = html`p { color: red; }</style>`;\n"
    for (name, file, source, anchor, removed, inserted) in [
      ("言語なし → python", "a.md", markdown, "```\ndef", 3, "```python"),
      ("js → py", "b.md", markdown, "js\nconst", 2, "py"),
      ("開きのフェンスを消す", "c.md", markdown, "```js", 5, ""),
      ("束ねた html の部分が消える", "d.js", tagged, "html`<style>", 0, "x"),
      ("束ねた html の部分を行ごと消すと、離れた残りの部分の構文が変わる", "e.js", split, "const a", 25, ""),
    ] {
      let (document, surface) = try open(file, source)
      XCTAssertTrue(document.waitUntilCaughtUp(), name)
      let at = (source as NSString).range(of: anchor).location
      surface.replace(NSRange(location: at, length: removed), with: inserted)
      XCTAssertTrue(document.waitUntilCaughtUp(), name)
      let (fresh, _) = try open("fresh-" + file, surface.text)
      XCTAssertTrue(fresh.waitUntilCaughtUp(), name)
      XCTAssertEqual(perUnit(document), perUnit(fresh), name)
    }
  }

  /// 構文木が誤りを含まなくなれば、その構文木の範囲を丸ごと作り直す——誤りを含む間に枠で落ちた、余白を超える構文（区画
  /// をいくつもまたぐコメント）の色が、誤りから遠い編集していない行にも戻る。
  func testFixingTheLastErrorRestoresColorsDroppedByTheFrame() throws {
    let comment = "/*\n" + String(repeating: "note\n", count: 30_000) + "*/\n"
    let source = "let = 1\n" + comment + "let b = 2\n"
    let (document, surface) = try open("crumbled.swift", source)
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30))
    let middle = document.text.lineStart(15_000)
    XCTAssertNotEqual(role(ofRow: 15_000, in: document), .comment, "前提: 誤りを含む間は枠で落ちる")

    surface.replace(NSRange(location: 4, length: 0), with: "a ")
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30))
    XCTAssertEqual(
      document.roles.roles(in: NSRange(location: middle, length: 4)).map(\.role), [.comment])
  }

  /// 字ごとの役割（本文全体）。
  private func perUnit(_ document: EditorDocument) -> [SyntaxRole?] {
    perUnit(document.roles)
  }

  private func perUnit(_ roles: RoleRuns) -> [SyntaxRole?] {
    var result = [SyntaxRole?](repeating: nil, count: roles.length)
    for span in roles.roles(in: NSRange(location: 0, length: roles.length)) {
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

  // MARK: - 打鍵が止むまで

  /// 開きのバッククォート（4 字目）を消すと、後ろの 3000 行がテンプレート文字列からコードに変わる JS。
  private static let template =
    "x = `\n" + String(repeating: "const Foo = new Bar(\"x\"); // Baz\n", count: 3000) + "`;\n"

  /// 開いてから一度も編集しない文書も、急かさずに文書全体の役割が揃う——編集が無ければ打鍵の止むのを待たない。
  func testAnOpenedDocumentCompletesWithoutHurrying() throws {
    let (document, _) = try open("opened.js", Self.template)
    XCTAssertTrue(pump(document, timeout: 30) { $0.isCaughtUp })
    XCTAssertEqual(role(ofRow: 2900, in: document), .string, "末尾の行まで作った")
  }

  /// 打鍵が続く間（待ちが明けるまで）は見えている行だけを作り直し、見えていない行は前の色をずらしたまま持つ。スクロール
  /// で見えた行は待たずに作る。結果を同期で待つ口は、待つ間だけ急かす——待った後の打鍵の群れは急かされない。
  func testWhileTypingOnlyTheVisibleLinesAreRebuilt() throws {
    let (document, surface) = try open("typing.js", Self.template, quietDelay: .seconds(3600))
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30))
    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30))
    show(row: 0, of: surface)

    surface.replace(NSRange(location: 4, length: 1), with: "")
    XCTAssertTrue(pump(document) { $0.isFirstColorReady })
    RunLoop.main.run(until: Date() + 0.2)
    XCTAssertEqual(role(ofRow: 2, in: document), .keyword, "見えている行は作り直した")
    XCTAssertEqual(role(ofRow: 2500, in: document), .string, "見えていない行は前の色のまま")
    XCTAssertFalse(document.isCaughtUp)

    show(row: 2500, of: surface)
    XCTAssertTrue(pump(document) { self.role(ofRow: 2500, in: $0) == .keyword }, "見えた行は待たずに作る")
    XCTAssertEqual(role(ofRow: 1500, in: document), .string, "見えていない行は前の色のまま")

    XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30), "待つ口は打鍵の止むのを待たずに揃える")
    XCTAssertEqual(role(ofRow: 1500, in: document), .keyword)
  }

  /// 打鍵が止んで待ちが明ければ、急かさなくても文書全体を作り直す。
  func testTheRestIsRebuiltWithoutHurryingOnceTypingStops() throws {
    let (document, surface) = try open("quiet.js", Self.template, quietDelay: .milliseconds(10))
    XCTAssertTrue(pump(document, timeout: 30) { $0.isCaughtUp })
    show(row: 0, of: surface)
    surface.replace(NSRange(location: 4, length: 1), with: "")
    XCTAssertTrue(pump(document, timeout: 30) { $0.isCaughtUp })
    XCTAssertEqual(role(ofRow: 2500, in: document), .keyword)
  }

  /// 急かさずに main を回して、`done` が成り立つか期限が来るまで待つ。
  private func pump(
    _ document: EditorDocument, timeout: TimeInterval = 5, _ done: (EditorDocument) -> Bool
  ) -> Bool {
    let deadline = Date() + timeout
    while !done(document), Date() < deadline { RunLoop.main.run(until: Date() + 0.005) }
    return done(document)
  }

  /// 面の見えている範囲を、行 `row` から 10 行にする。
  private func show(row: Int, of surface: FakeTextSurface) {
    let document = try? XCTUnwrap(surface.delegate as? EditorDocument)
    surface.viewport = TextViewport(
      firstVisible: document?.text.lineStart(row) ?? 0, visibleLines: 10)
    surface.delegate?.surfaceDidChangeViewport(surface)
  }

  /// 行の先頭の字の役割。
  private func role(ofRow row: Int, in document: EditorDocument) -> SyntaxRole? {
    document.roles.roles(in: NSRange(location: document.text.lineStart(row), length: 1)).first?.role
  }

  /// 閉じた文書の構文木（構文の裏の仕事）は、手放す裏の仕事が最後の参照を落とす——裏へ渡した後の main に参照が残って
  /// いれば、裏が先に済んだとき（多いコアでは起こりうる）最後の解放が main で起き、大きな木の解放で main が止まる。裏へ
  /// 渡した部品を裏で落とし切った時点（文書の解放の途中）で、構文の裏の仕事がもう無いことを見る。
  func testClosingHandsTheLastReferenceOfTheSyntaxTreeToTheBackground() throws {
    let result = OSAllocatedUnfairLock<(sawWorker: Bool, aliveAfterDrop: Bool)?>(initialState: nil)
    do {
      let (document, _) = try open("close.swift", "let a = 1\n")
      XCTAssertTrue(document.waitUntilCaughtUp())
      document.releaseParts = { parcel in
        weak var worker = parcel.withLock { $0?.syntax }
        let saw = worker != nil
        DispatchQueue.global().sync { parcel.withLock { $0 = nil } }
        result.withLock { $0 = (saw, worker != nil) }
      }
    }
    let observed = try XCTUnwrap(result.withLock { $0 }, "前提: 文書が閉じて部品を手放した")
    XCTAssertTrue(observed.sawWorker, "前提: 構文の裏の仕事を手放す部品に入れた")
    XCTAssertFalse(observed.aliveAfterDrop, "裏で落とした後に main が構文の裏の仕事を持っていない")
  }
}
