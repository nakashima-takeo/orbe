import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// エディター面に結んだプロジェクト検索——選択は一致の位置で持ち（編集で一致が消えても F4 は飛ばさない）、焦点の文書の編集で
/// 一致をずらして少し後に探し直し、外で書き換えられた開いている文書も探し直す。一致を開けば選択して中央へ、焦点はシングル
/// クリックなら結果に、ダブルクリック・Enter・F4 なら本文へ。
///
/// 壊れると何が起きるか。F4 で渡りながら 1 件ずつ手で直すと、直すたびに次の 1 件を黙って飛ばす。「現在の一致」の地が選んで
/// いない一致に出る。編集の後、地と押して開く位置が字からずれる。エージェントが書き換えた文書の結果が古いまま残る。
@MainActor
final class ProjectSearchPaneTests: OrbeTestCase {
  struct Hosted {
    let repo: TempGitRepo
    let tab: TerminalTab
    let pane: EditorPaneView
    let window: NSWindow
    @MainActor var search: ProjectSearch { pane.projectSearch }
  }

  /// 根 `repo` のタブの面だけを窓に載せる。端末は載せない——端末の shell は起動しないので、その cwd の報告（OSC 7）が面の根を
  /// 動かさない（検索は根に依る）。
  func host(_ files: [String: String]) throws -> Hosted {
    let repo = try TempGitRepo(name: "orbe-search-pane")
    addTeardownBlock { repo.cleanup() }
    for (path, text) in files { try repo.write(path, text) }
    let tab = TerminalTab(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = pane
    pane.layoutSubtreeIfNeeded()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    return Hosted(repo: repo, tab: tab, pane: pane, window: window)
  }

  /// 検索パネルを出して即時に検索し、終わるまで待つ。
  func searchAll(_ hosted: Hosted, _ pattern: String) {
    hosted.pane.showProjectSearch(seed: nil)
    hosted.search.setPattern(pattern)
    hosted.search.search()
    pumpMain(until: { hosted.search.phase == .done }, "検索が終わる")
  }

  func open(_ hosted: Hosted, _ path: String) throws -> EditorDocument {
    let document = try hosted.tab.editor.open(hosted.repo.url(path), as: .pinned)
    hosted.pane.layoutSubtreeIfNeeded()
    return document
  }

  func replace(_ document: EditorDocument, _ range: NSRange, with text: String) {
    document.surface.selectedRange = range
    if text.isEmpty {
      document.surface.responder.deleteBackward(nil)
    } else {
      document.surface.responder.perform(#selector(NSResponder.insertText(_:)), with: text)
    }
  }

  /// 選択の行（見せている文書の本文）。
  func selectedText(_ hosted: Hosted) -> String? {
    guard let document = hosted.pane.document else { return nil }
    return document.text.substring(document.surface.selectedRange)
  }

  func selectedLine(_ hosted: Hosted) -> Int? {
    guard let document = hosted.pane.document else { return nil }
    return document.text.row(containing: document.surface.selectedRange.location)
  }

  // MARK: - 選択は一致の位置で持つ

  /// F4 で開いた一致を編集で消しても、次の F4 はその位置の後ろの一致へ進み（飛ばさない）、⇧F4 は前の一致へ戻る。
  func testStepAfterTheSelectedMatchIsEditedAwayDoesNotSkip() throws {
    let hosted = try host(["a.txt": "needle 1\nneedle 2\nneedle 3\nneedle 4\n"])
    searchAll(hosted, "needle")
    hosted.search.step(forward: true)
    hosted.search.step(forward: true)
    XCTAssertEqual(selectedLine(hosted), 1)
    let document = try XCTUnwrap(hosted.pane.document)

    replace(document, NSRange(location: 9, length: 2), with: "xx")
    XCTAssertNil(hosted.search.selection, "消えた一致の行は選ばない")
    XCTAssertEqual(hosted.pane.findGround.current, [], "現在の一致の地を別の一致へ移さない")
    hosted.search.step(forward: true)
    XCTAssertEqual(selectedLine(hosted), 2, "F4 は消えた一致の後ろの一致へ")
    XCTAssertEqual(selectedText(hosted), "needle")

    replace(document, NSRange(location: 18, length: 2), with: "xx")
    hosted.search.step(forward: false)
    XCTAssertEqual(selectedLine(hosted), 0, "⇧F4 は消えた一致の前の一致へ")
  }

  /// 選んだ一致より前の一致が編集で消えても、探し直した後も、同じ一致を選び続ける。
  func testTheSelectionStaysOnItsMatchThroughEditsAndRefreshes() throws {
    let hosted = try host(["a.txt": "needle 1\nneedle 2\nneedle 3\n"])
    searchAll(hosted, "needle")
    for _ in 0..<3 { hosted.search.step(forward: true) }
    let document = try XCTUnwrap(hosted.pane.document)
    XCTAssertEqual(selectedLine(hosted), 2)

    replace(document, NSRange(location: 0, length: 9), with: "")
    let third = NSRange(location: 9, length: 6)
    XCTAssertEqual(hosted.search.selection, ProjectSearch.RowID(path: "a.txt", match: 1))
    XCTAssertEqual(hosted.pane.findGround.current, [third])

    pumpMain(until: { hosted.search.results["a.txt"]?.document?.version == document.version })
    XCTAssertEqual(hosted.search.selection, ProjectSearch.RowID(path: "a.txt", match: 1), "探し直しの後も")
    XCTAssertEqual(hosted.pane.findGround.current, [third])
  }

  /// ディスクの結果から開いた一致は、開いた文書の区間に写しても同じ一致を選んでいる。
  func testOpeningADiskResultKeepsTheSameMatchSelected() throws {
    let hosted = try host(["b.txt": "x\nneedle a needle b\n"])
    searchAll(hosted, "needle")
    XCTAssertNil(hosted.search.results["b.txt"]?.document, "前提: ディスクの結果")

    hosted.search.click(ProjectSearch.RowID(path: "b.txt", match: 1))

    XCTAssertEqual(hosted.pane.document?.url, hosted.repo.url("b.txt"))
    XCTAssertNotNil(hosted.search.results["b.txt"]?.document, "開いた文書のまとまりとして扱う")
    XCTAssertEqual(hosted.search.selection, ProjectSearch.RowID(path: "b.txt", match: 1))
    XCTAssertEqual(hosted.pane.document?.surface.selectedRange, NSRange(location: 11, length: 6))
  }

  /// 検索の後・開く前に外で書き換わったファイルを結果から開くと、今の本文と字の違う一致は落とし（無関係な字を選ばない・
  /// 地を敷かない）、その文書を探し直す。字の合う一致はそのまま使える。
  func testOpeningADiskResultRewrittenOutsideDropsTheStaleMatchesAndSearchesAgain() throws {
    let hosted = try host(["b.txt": "x\nneedle a needle b\n"])
    searchAll(hosted, "needle")
    XCTAssertNil(hosted.search.results["b.txt"]?.document, "前提: ディスクの結果")
    try hosted.repo.write("b.txt", "x\nneedle a zzzzzz b\nneedle\n")

    hosted.search.click(ProjectSearch.RowID(path: "b.txt", match: 1))

    let document = try XCTUnwrap(hosted.pane.document)
    XCTAssertEqual(document.url, hosted.repo.url("b.txt"))
    XCTAssertEqual(document.surface.selectedRange.length, 0, "字の違う一致を選ばない")
    XCTAssertNil(hosted.search.selection, "落ちた一致の行は選ばない")
    XCTAssertEqual(
      hosted.search.results["b.txt"]?.document?.ranges, [NSRange(location: 2, length: 6)],
      "字の合う一致は残る")
    XCTAssertEqual(hosted.pane.findGround.matches, [NSRange(location: 2, length: 6)])
    pumpMain(
      until: {
        hosted.search.results["b.txt"]?.document?.ranges
          == [NSRange(location: 2, length: 6), NSRange(location: 20, length: 6)]
      }, "今の本文で探し直す")
  }

  /// 結果に出ている未編集の文書を閉じ、外で書き換わってから開き直す（版は 0 から数え直し）と、閉じた文書の本文で取った区間を
  /// 今の本文と照合し、字の違う一致を落として探し直す。
  func testReopeningAnUneditedDocumentRewrittenOutsideDropsTheStaleMatches() throws {
    let hosted = try host(["a.txt": "x\nneedle a needle b\n"])
    let closed = try open(hosted, "a.txt")
    searchAll(hosted, "needle")
    XCTAssertEqual(hosted.search.results["a.txt"]?.document?.version, 0, "前提: 文書の結果")
    hosted.tab.editor.close(closed)
    try hosted.repo.write("a.txt", "x\nneedle a zzzzzz b\nneedle\n")

    hosted.search.click(ProjectSearch.RowID(path: "a.txt", match: 1))

    let document = try XCTUnwrap(hosted.pane.document)
    XCTAssertFalse(document === closed, "前提: 開き直した文書")
    XCTAssertEqual(document.version, 0, "前提: 版は 0 から")
    XCTAssertEqual(document.surface.selectedRange.length, 0, "字の違う一致を選ばない")
    XCTAssertEqual(
      hosted.search.results["a.txt"]?.document?.ranges, [NSRange(location: 2, length: 6)],
      "字の合う一致は残る")
    XCTAssertEqual(hosted.pane.findGround.matches, [NSRange(location: 2, length: 6)])
    pumpMain(
      until: {
        hosted.search.results["a.txt"]?.document?.ranges
          == [NSRange(location: 2, length: 6), NSRange(location: 20, length: 6)]
      }, "今の本文で探し直す")
  }

  // MARK: - 開いている文書の探し直し

  /// 焦点の文書を編集すると、一致の位置はすぐ編集に合わせてずれ、少し後にその文書だけ探し直す（一致 0 なら消える）。
  func testEditingShiftsTheMatchesAtOnceAndSearchesAgainShortlyAfter() throws {
    let hosted = try host(["a.txt": "x needle\n", "b.txt": "needle\n"])
    let document = try open(hosted, "a.txt")
    searchAll(hosted, "needle")

    replace(document, NSRange(location: 0, length: 0), with: "abc")
    XCTAssertEqual(
      hosted.search.results["a.txt"]?.document?.ranges, [NSRange(location: 5, length: 6)])
    XCTAssertEqual(hosted.search.results["a.txt"]?.matches.first?.preview.before, "x ", "探し直すまで前の行")
    pumpMain(until: { hosted.search.results["a.txt"]?.matches.first?.preview.before == "abcx " })

    replace(document, NSRange(location: 0, length: document.text.length), with: "gone\n")
    pumpMain(until: { hosted.search.results["a.txt"] == nil }, "一致 0 のまとまりは消える")
    XCTAssertEqual(hosted.search.results.files.map(\.path), ["b.txt"])
  }

  /// 焦点に無い開いている文書が外で書き換えられて差し替わると、少し後にその文書を探し直す。
  func testAnOpenDocumentRewrittenOutsideIsSearchedAgain() throws {
    let hosted = try host(["a.txt": "needle\n", "b.txt": "needle\n"])
    _ = try open(hosted, "b.txt")
    _ = try open(hosted, "a.txt")
    searchAll(hosted, "needle")
    XCTAssertEqual(hosted.search.results["b.txt"]?.count, 1)

    try hosted.repo.write("b.txt", "needle needle needle\n")
    pumpMain(until: { hosted.search.results["b.txt"]?.count == 3 }, "外の書き換えで探し直す")
  }

  /// 探し直すのは結果に出ている文書だけ。結果に無い文書に一致が生じても足さない。
  func testANewMatchInADocumentOutsideTheResultsIsNotAdded() throws {
    let hosted = try host(["a.txt": "needle\n", "c.txt": "other\n"])
    let document = try open(hosted, "c.txt")
    searchAll(hosted, "needle")

    replace(document, NSRange(location: 0, length: 0), with: "needle ")
    XCTAssertTrue(
      holds(for: ProjectSearch.refreshDelay * 2) { hosted.search.results["c.txt"] == nil })
  }

  func holds(for seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      guard condition() else { return false }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
  }
}
