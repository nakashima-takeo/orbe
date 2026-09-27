import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// プロジェクト検索の実行——本物の git と開いている文書（保存前の中身）を合わせ、ファイルごとにパスの順で結果を積む。前の結果は
/// 新しい結果が最初に届くまで残し、止めればその検索で届いたものだけを残す（何も届いていなければ前の問いの結果を消す）。
/// 無出力で切らず、上限・止める・タブを閉じるで git を止め、終わり方を問いのエラーに読む。
///
/// 壊れると何が起きるか。打つ・切り替えるたびに結果がちらつく。遅い検索を止めると前の語の結果が今の語の結果として残る。
/// 一致の無い開いている文書だけで結果が空になる。大きな根で珍しい語を探すと途中で「git が断った」が出る。止めた・閉じた
/// タブの git が走り続ける。保存前の編集が結果に出ない、検索の最中に編集した文書が結果から消える。
@MainActor
final class ProjectSearchTests: OrbeTestCase {
  struct Fixture {
    let repo: TempGitRepo
    let session: EditorSession
    let search: ProjectSearch
  }

  func fixture(runner: GitRunner = .shared) throws -> Fixture {
    let repo = try TempGitRepo(name: "orbe-search")
    addTeardownBlock { repo.cleanup() }
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let search = ProjectSearch(root: repo.root, runner: runner)
    search.documents = { [weak session] in session?.documents ?? [] }
    return Fixture(repo: repo, session: session, search: search)
  }

  func gate(_ fixture: Fixture) throws -> GrepGate {
    let gate = try GrepGate(fixture.repo)
    addTeardownBlock { gate.close() }
    return gate
  }

  /// Enter と同じく即時に検索し、終わるまで待つ。
  func search(_ search: ProjectSearch, _ pattern: String) {
    search.setPattern(pattern)
    search.search()
    pumpMain(until: { search.phase == .done }, "検索が終わる")
  }

  func paths(_ search: ProjectSearch) -> [String] { search.results.files.map(\.path) }

  /// 本文の `range` を `text` に置き換える（打鍵と同じ入力の口から）。
  func replace(_ document: EditorDocument, _ range: NSRange, with text: String) {
    document.surface.selectedRange = range
    document.surface.responder.perform(Selector(("insertText:")), with: text)
  }

  /// 条件が `seconds` の間ずっと成り立つ（来てはいけないものが来ないこと）。
  func holds(for seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      guard condition() else { return false }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
  }

  // MARK: - 結果

  func testResultsAreGroupedByFileInPathOrder() throws {
    let f = try fixture()
    try f.repo.write("b.txt", "x needle\n")
    try f.repo.write("a10.txt", "needle needle\n")
    try f.repo.write("a2.txt", "\n  needle\n")
    try f.repo.write("sub/c.txt", "needle\n")

    search(f.search, "needle")

    XCTAssertEqual(paths(f.search), ["a2.txt", "a10.txt", "b.txt", "sub/c.txt"])
    XCTAssertEqual(f.search.results.total, 5)
    let a2 = try XCTUnwrap(f.search.results["a2.txt"]?.matches.first)
    XCTAssertEqual(a2.line, 1)
    XCTAssertEqual(a2.column, NSRange(location: 2, length: 6))
    XCTAssertEqual(a2.preview, SearchPreview(before: "", match: "needle", after: ""))
    XCTAssertNil(f.search.error)
  }

  /// 開いている文書は保存前の中身を探し、ディスクの同じファイルの行は出さない。
  func testAnOpenDocumentIsSearchedWithItsUnsavedText() throws {
    let f = try fixture()
    try f.repo.write("a.txt", "needle on disk\n")
    let document = try f.session.open(f.repo.url("a.txt"))
    replace(
      document, NSRange(location: 0, length: document.text.length), with: "x\nneedle unsaved\n")

    search(f.search, "needle")

    let file = try XCTUnwrap(f.search.results["a.txt"])
    XCTAssertEqual(paths(f.search), ["a.txt"], "同じファイルは 1 つ")
    XCTAssertEqual(file.matches.map(\.line), [1])
    XCTAssertEqual(file.matches.first?.preview.after, " unsaved")
    XCTAssertEqual(
      file.document, .init(ranges: [NSRange(location: 2, length: 6)], version: document.version))
  }

  /// ディスクは git（PCRE2）と ICU の両方が一致とする行だけを拾う。両方が同じと見る大小無視（`ärger` と `ÄRGER`）は
  /// ディスクと開いている文書で同じ位置に当たり、ICU だけが同じと見る畳み込み（`straße` と `STRASSE`）は開いている文書だけが
  /// 拾う。
  func testTheDiskFindsOnlyWhatBothEnginesMatch() throws {
    let f = try fixture()
    let text = "STRASSE\n😀 ÄRGER\n"
    try f.repo.write("disk.txt", text)
    try f.repo.write("open.txt", text)
    _ = try f.session.open(f.repo.url("open.txt"))

    search(f.search, "ärger")
    XCTAssertEqual(paths(f.search), ["disk.txt", "open.txt"])
    for path in ["disk.txt", "open.txt"] {
      let match = try XCTUnwrap(f.search.results[path]?.matches.first, path)
      XCTAssertEqual(match.line, 1, path)
      XCTAssertEqual(match.column, NSRange(location: 3, length: 5), "\(path): 行の中の位置は UTF-16")
    }

    search(f.search, "straße")
    XCTAssertEqual(paths(f.search), ["open.txt"])
  }

  // MARK: - 前の結果の置き換え

  /// Enter・切替・打鍵のどの検索でも、前の結果は新しい結果が最初に届くまで残る。
  func testThePreviousResultsStayUntilTheNewResultsArrive() throws {
    let f = try fixture()
    try f.repo.write("n.txt", "needle\n")
    try f.repo.write("o.txt", "other\n")
    var typed: (@MainActor () -> Void)?
    f.search.typingDelay.schedule = { _, fire in typed = fire }
    search(f.search, "needle")

    f.search.setPattern("other")
    XCTAssertEqual(f.search.phase, .done, "打鍵はすぐには探さない")
    try XCTUnwrap(typed)()
    XCTAssertEqual(f.search.phase, .searching)
    XCTAssertEqual(paths(f.search), ["n.txt"], "打鍵の検索: 届くまで前の結果が残る")
    pumpMain(until: { f.search.phase == .done })
    XCTAssertEqual(paths(f.search), ["o.txt"])

    f.search.toggle(.matchCase)
    XCTAssertEqual(paths(f.search), ["o.txt"], "切替の検索: 届くまで前の結果が残る")
    pumpMain(until: { f.search.phase == .done })

    f.search.setPattern("needle")
    f.search.search()
    XCTAssertEqual(paths(f.search), ["o.txt"], "Enter の検索: 届くまで前の結果が残る")
    pumpMain(until: { f.search.phase == .done })
    XCTAssertEqual(paths(f.search), ["n.txt"])
  }

  /// 一致の無い開いている文書だけが先に届いても、前の結果を空にしない。
  func testAnOpenDocumentWithoutMatchesDoesNotReplaceThePreviousResults() throws {
    let f = try fixture()
    try f.repo.write("n.txt", "needle\n")
    try f.repo.write("o.txt", "other\n")
    try f.repo.write("open.txt", "nothing here\n")
    _ = try f.session.open(f.repo.url("open.txt"))
    search(f.search, "needle")
    let gate = try gate(f)

    f.search.setPattern("other")
    f.search.search()
    pumpMain(until: { GrepGate.isGrepRunning }, "git が走る")
    XCTAssertTrue(
      holds(for: 0.3) { paths(f.search) == ["n.txt"] }, "開いている文書の結果（一致 0）では置き換えない")
    gate.open()
    pumpMain(until: { f.search.phase == .done })
    XCTAssertEqual(paths(f.search), ["o.txt"])
  }

  // MARK: - 止める

  /// 新しい結果がまだ 1 つも届かないうちに止めると、前の問いの結果は消える（今の問いの結果として見せない）。
  func testStoppingBeforeAnyNewResultArrivesDropsThePreviousResults() throws {
    let f = try fixture()
    try f.repo.write("n.txt", "needle\n")
    try f.repo.write("o.txt", "other\n")
    var typed: (@MainActor () -> Void)?
    f.search.typingDelay.schedule = { _, fire in typed = fire }
    search(f.search, "needle")

    f.search.setPattern("other")
    try XCTUnwrap(typed)()
    f.search.stop()
    XCTAssertEqual(f.search.phase, .done)
    XCTAssertTrue(f.search.results.isEmpty)
    XCTAssertTrue(holds(for: 0.3) { f.search.results.isEmpty }, "止めた検索の結果は後から届かない")

    search(f.search, "needle")
    f.search.setPattern("other")
    f.search.search()
    f.search.escapeInResults()
    XCTAssertEqual(f.search.phase, .done, "結果の列の Esc も止める")
    XCTAssertTrue(f.search.results.isEmpty)
  }

  /// 止めると、その検索で届いた結果は残り、git は止まる。エラーにはならない。
  func testStoppingKeepsWhatArrivedAndStopsGit() throws {
    let f = try fixture()
    try f.repo.write("open.txt", "needle\n")
    try f.repo.write("disk.txt", "needle\n")
    _ = try f.session.open(f.repo.url("open.txt"))
    _ = try gate(f)
    var slow: (@MainActor () -> Void)?
    f.search.slowDelay.schedule = { _, fire in slow = fire }

    f.search.setPattern("needle")
    f.search.search()
    pumpMain(until: { GrepGate.isGrepRunning }, "git が走る")
    pumpMain(until: { paths(f.search) == ["open.txt"] }, "開いている文書の結果が先に届く")
    try XCTUnwrap(slow)()
    XCTAssertEqual(f.search.phase, .slow, "2 秒を超えた検索")

    f.search.stop()
    XCTAssertEqual(f.search.phase, .done)
    XCTAssertEqual(paths(f.search), ["open.txt"])
    XCTAssertNil(f.search.error)
    pumpMain(until: { !GrepGate.isGrepRunning }, "止めた git は終わる")
  }

  /// タブを閉じる（検索の状態が解放される）と、走っている git も止まる。
  func testClosingTheTabStopsItsGit() throws {
    let f = try fixture()
    _ = try gate(f)
    var search: ProjectSearch? = ProjectSearch(root: f.repo.root)
    search?.setPattern("needle")
    search?.search()
    pumpMain(until: { GrepGate.isGrepRunning }, "git が走る")
    search = nil
    pumpMain(until: { !GrepGate.isGrepRunning }, "閉じたタブの git は終わる")
  }

  /// 一致の無い間 git が何も出さなくても（無出力の打ち切りより長くても）切らず、終われば結果とともに完了する。
  func testASilentSearchIsNotCut() throws {
    let f = try fixture(runner: GitRunner(idleTimeout: 0.3))
    try f.repo.write("n.txt", "needle\n")
    let gate = try gate(f)

    f.search.setPattern("needle")
    f.search.search()
    pumpMain(until: { GrepGate.isGrepRunning }, "git が走る")
    XCTAssertTrue(holds(for: 1) { GrepGate.isGrepRunning }, "無出力が打ち切りの上限を超えても git は生きている")
    gate.open()
    pumpMain(until: { f.search.phase == .done })
    XCTAssertEqual(paths(f.search), ["n.txt"])
    XCTAssertNil(f.search.error)
  }

  // MARK: - 上限・エラー

  /// 上限（20000 件）に達すると git を止めて終え、打ち切りを示す。エラーにはしない。
  func testTheLimitEndsTheSearchWithoutAnError() throws {
    let f = try fixture()
    try f.repo.write("many.txt", String(repeating: "x\n", count: 25_000))

    search(f.search, "x")

    XCTAssertEqual(f.search.results.total, ProjectSearchResults.limit)
    XCTAssertTrue(f.search.results.isLimited)
    XCTAssertNil(f.search.error)
  }

  func testQueryErrors() throws {
    let f = try fixture()
    try f.repo.write("n.txt", "needle\n")
    search(f.search, "needle")

    f.search.toggle(.regex)
    f.search.setPattern("(")
    f.search.search()
    XCTAssertEqual(f.search.error, .invalidPattern, "ICU が断った式は探さない")
    XCTAssertEqual(f.search.phase, .idle)
    XCTAssertTrue(f.search.results.isEmpty)

    search(f.search, "(?w)needle")
    guard case .disk(.refused(let reason)) = f.search.error else {
      return XCTFail("git だけが断った式は git の理由: \(String(describing: f.search.error))")
    }
    XCTAssertTrue(reason.hasPrefix("fatal:"), reason)

    let gone = ProjectSearch(root: f.repo.root + "/gone")
    search(gone, "needle")
    XCTAssertEqual(gone.error, .disk(.couldNotStart), "git を起動できない")
  }

  // MARK: - 問いと根

  func testTypingWaitsAndEmptyingThePatternStopsAndClears() throws {
    let f = try fixture()
    try f.repo.write("n.txt", "needle\n")
    var typed: (@MainActor () -> Void)?
    f.search.typingDelay.schedule = { _, fire in typed = fire }

    f.search.setPattern("needle")
    XCTAssertEqual(f.search.phase, .idle, "打つのが止まるまで探さない")
    try XCTUnwrap(typed)()
    pumpMain(until: { f.search.phase == .done })
    XCTAssertEqual(paths(f.search), ["n.txt"])

    f.search.setPattern("")
    XCTAssertEqual(f.search.phase, .idle)
    XCTAssertTrue(f.search.results.isEmpty)
  }

  /// 根が変わると結果を捨て、求められれば新しい根を今の問いで探す。
  func testChangingTheRootDropsTheResults() throws {
    let f = try fixture()
    try f.repo.write("n.txt", "needle\n")
    let other = try TempGitRepo(name: "orbe-search-other")
    addTeardownBlock { other.cleanup() }
    try other.write("m.txt", "needle\n")
    search(f.search, "needle")

    f.search.setRoot(other.root, searchNow: false)
    XCTAssertTrue(f.search.results.isEmpty)
    XCTAssertEqual(f.search.phase, .idle)

    f.search.setRoot(f.repo.root, searchNow: true)
    pumpMain(until: { f.search.phase == .done })
    XCTAssertEqual(paths(f.search), ["n.txt"])
  }

  // MARK: - 開いている文書の版

  /// 検索の最中に開いている文書を編集しても、その文書の結果は消えず、今の本文で出る。
  func testEditingADocumentDuringTheSearchKeepsItsResults() throws {
    let f = try fixture()
    try f.repo.write("open.txt", "needle\n")
    let document = try f.session.open(f.repo.url("open.txt"))

    f.search.setPattern("needle")
    f.search.search()
    replace(document, NSRange(location: 0, length: 0), with: "needle ")
    pumpMain(until: {
      f.search.phase == .done && f.search.results["open.txt"]?.document?.version == document.version
    })
    XCTAssertEqual(
      f.search.results["open.txt"]?.document?.ranges,
      [NSRange(location: 0, length: 6), NSRange(location: 7, length: 6)])
  }

  /// 検索の途中で開いた文書は、ディスクの結果が届いた時点で文書から探し直す（同じファイルは開いている文書が勝つ）。
  func testADocumentOpenedDuringTheSearchIsSearchedFromItsText() throws {
    let f = try fixture()
    try f.repo.write("b.txt", "needle\n")
    let gate = try gate(f)

    f.search.setPattern("needle")
    f.search.search()
    pumpMain(until: { GrepGate.isGrepRunning }, "git が走る")
    let document = try f.session.open(f.repo.url("b.txt"))
    replace(document, NSRange(location: 0, length: 0), with: "needle ")
    gate.open()

    pumpMain(until: {
      f.search.phase == .done && f.search.results["b.txt"]?.document?.version == document.version
    })
    XCTAssertEqual(f.search.results["b.txt"]?.count, 2, "保存前の中身で探し直す")
  }
}
