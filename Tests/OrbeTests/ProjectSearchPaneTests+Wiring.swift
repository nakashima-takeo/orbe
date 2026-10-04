import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 面の結線——一致の地は検索パネルが見えている間だけ ⌘F の一致との和で本文と俯瞰に出る、パネルの中のキー（⌥⌘C / W / R・
/// ⌘↓ / ⌘↑）、エディター面の F4 / ⇧F4、開き方と焦点（シングルクリックは仮のタブで結果に残り、ダブルクリック・Enter は
/// 普通のタブで本文へ、一致は中央へ、遅れて走るキーの開きは焦点に触らない）、パネルを隠すと焦点は本文へ戻り、焦点の要求は
/// 後で奪わない、裏のタブの cd では探さない。
///
/// 壊れると何が起きるか。パネルを隠しても地が残る、⌘F の地が消える。パネルのキーが効かない、本文の打鍵を奪う。端末の F4 が
/// 奪われる、本文の F4 が効かない。クリックで渡るたびに焦点が本文へ飛ぶ、タブが増える。↓ を離してすぐ本文・端末へ移った
/// 焦点が結果へ引き戻される。隠れたパネルに焦点が取り残されて打鍵が消える。見ていないタブが cd のたびに根の全体を探す。
extension ProjectSearchPaneTests {
  typealias RowID = ProjectSearch.RowID

  var f4: NSEvent { .key(String(UnicodeScalar(NSEvent.SpecialKey.f4.rawValue)!), []) }

  func arrow(_ key: NSEvent.SpecialKey) -> NSEvent {
    .key(String(UnicodeScalar(key.rawValue)!), .command)
  }

  func textHasFocus(_ hosted: Hosted) -> Bool {
    guard let document = hosted.pane.document else { return false }
    return hosted.window.firstResponder === document.surface.responder
  }

  // MARK: - 一致の地

  /// pane が焦点の文書の面へ押した一致の地（出す前の状態を出してから読む）。
  func pushedFindGround(_ hosted: Hosted) -> [NSRange] {
    guard let surface = hosted.pane.document?.surface as? MetalTextSurface else { return [] }
    surface.flush()
    return surface.material.read().highlights[.findMatch]
  }

  func testTheProjectMatchesJoinTheFindGroundOnlyWhileThePanelIsShown() throws {
    let hosted = try host(["a.txt": "needle x needle\n"])
    _ = try open(hosted, "a.txt")
    searchAll(hosted, "needle")
    let project = [NSRange(location: 0, length: 6), NSRange(location: 9, length: 6)]
    XCTAssertEqual(hosted.pane.findGround.matches, project)
    hosted.search.select(RowID(path: "a.txt", match: 1))
    XCTAssertEqual(hosted.pane.findGround.current, [NSRange(location: 9, length: 6)], "選んだ一致が現在の一致")
    XCTAssertEqual(pushedFindGround(hosted), project, "面へ押す（面は本文と俯瞰に描く）")

    hosted.pane.showSearch()
    catchUp(hosted.pane)
    hosted.pane.search.setNeedle("x")
    catchUp(hosted.pane)
    XCTAssertEqual(
      hosted.pane.findGround.matches,
      [
        NSRange(location: 0, length: 6), NSRange(location: 7, length: 1),
        NSRange(location: 9, length: 6),
      ], "⌘F と同時に使えば両方の一致")

    hosted.pane.sidebar.select(.files)
    pumpMain(
      until: { pushedFindGround(hosted) == [NSRange(location: 7, length: 1)] },
      "パネルを隠すとプロジェクト検索の地は消え、⌘F の地は残る")
    XCTAssertEqual(hosted.pane.findGround.matches, [NSRange(location: 7, length: 1)])
  }

  // MARK: - キー

  func testPanelKeysToggleOptionsAndMoveBetweenTheFieldAndTheResults() throws {
    let hosted = try host(["a.txt": "needle\n"])
    let pane = hosted.pane
    let document = try open(hosted, "a.txt")
    searchAll(hosted, "needle")
    pumpMain(until: { hosted.search.focusedArea == .field }, "⌘⇧F で入力欄に焦点")

    for (key, option) in [("c", \SearchQuery.matchCase), ("w", \.wholeWord), ("r", \.isRegex)] {
      XCTAssertTrue(pane.performKeyEquivalent(with: .key(key, [.command, .option])), key)
      XCTAssertTrue(hosted.search.query[keyPath: option], key)
    }
    pumpMain(until: { hosted.search.phase == .done })

    XCTAssertTrue(pane.performKeyEquivalent(with: arrow(.downArrow)))
    pumpMain(until: { hosted.search.focusedArea == .results }, "⌘↓ で結果の列へ")
    XCTAssertEqual(hosted.search.selection, RowID(path: "a.txt", match: nil), "未選択なら先頭を選ぶ")
    XCTAssertTrue(pane.performKeyEquivalent(with: arrow(.upArrow)))
    pumpMain(until: { hosted.search.focusedArea == .field }, "先頭の ⌘↑ で入力欄へ")

    hosted.window.makeFirstResponder(document.surface.responder)
    _ = pane.performKeyEquivalent(with: .key("c", [.command, .option]))
    XCTAssertTrue(hosted.search.query.matchCase, "パネルの外（本文）では切り替えない")
  }

  /// エディター面の F4 / ⇧F4 は次・前の一致を開いて本文へ焦点を移し、隠れた検索パネルを出す。面の外と、結果が無いときは
  /// 素通しする。
  func testF4InTheEditorStepsThroughTheResults() throws {
    let hosted = try host(["a.txt": "needle\n", "b.txt": "needle\n"])
    let pane = hosted.pane
    let document = try open(hosted, "a.txt")
    searchAll(hosted, "needle")
    pane.sidebar.select(.files)
    hosted.window.makeFirstResponder(document.surface.responder)

    XCTAssertTrue(pane.handleStepKey(f4))
    XCTAssertEqual(hosted.search.selection, RowID(path: "a.txt", match: 0))
    XCTAssertTrue(pane.showsSearchPanel, "隠れていれば出す")
    XCTAssertTrue(textHasFocus(hosted))
    XCTAssertTrue(pane.handleStepKey(.key(f4.characters!, .shift)))
    XCTAssertEqual(hosted.search.selection, RowID(path: "b.txt", match: 0), "⇧F4 は前へ（先頭の前は末尾）")
    XCTAssertEqual(pane.document?.url, hosted.repo.url("b.txt"))
    XCTAssertTrue(textHasFocus(hosted))

    hosted.window.makeFirstResponder(nil)
    XCTAssertFalse(pane.handleStepKey(f4), "面の外（端末など）では奪わない")
    hosted.window.makeFirstResponder(pane.focusTarget)
    hosted.search.clear()
    XCTAssertFalse(pane.handleStepKey(f4), "結果が無ければ素通し")
  }

  // MARK: - 開き方と焦点

  /// シングルクリックは開いて焦点を結果に残し、ダブルクリックは本文へ移す。一致の行は本文の中央へ来る。
  func testClickingOpensTheMatchCenteredAndKeepsOrMovesTheFocus() throws {
    var lines = (0..<200).map { "line \($0)" }
    lines[60] = "needle sixty"
    lines[64] = "needle sixty-four"
    let hosted = try host(["long.txt": lines.joined(separator: "\n") + "\n"])
    searchAll(hosted, "needle")
    hosted.search.focusResults()
    pumpMain(until: { hosted.search.focusedArea == .results }, "結果の列に焦点")

    for (index, line) in [(0, 60), (1, 64)] {
      hosted.search.click(RowID(path: "long.txt", match: index))
      let document = try XCTUnwrap(hosted.pane.document)
      XCTAssertEqual(document.surface.selectedRange.length, 6, "一致が選択される")
      XCTAssertEqual(document.text.row(containing: document.surface.selectedRange.location), line)
      let viewport = document.surface.viewport
      let first = CGFloat(document.text.row(containing: viewport.firstVisible))
      XCTAssertEqual(
        first + viewport.visibleLines / 2, CGFloat(line) + 0.5, accuracy: 1,
        "一致の行が中央へ（見えていても）")
      XCTAssertTrue(hosted.pane.focusIsInSidebar, "シングルクリックは焦点を結果に残す")
    }

    hosted.search.doubleClick(RowID(path: "long.txt", match: 0))
    XCTAssertTrue(textHasFocus(hosted), "ダブルクリックは本文へ")
  }

  /// 一致のクリックは仮のタブで開き、次のクリックがそのタブを入れ替える（タブが増えない）。ダブルクリックは普通のタブにし、
  /// 次のクリックは別の仮のタブで開く。
  func testClickingMatchesBrowsesInOnePreviewTab() throws {
    let hosted = try host(["a.txt": "needle\n", "b.txt": "needle\n", "c.txt": "needle\n"])
    searchAll(hosted, "needle")
    let editor = hosted.tab.editor

    hosted.search.click(RowID(path: "a.txt", match: 0))
    hosted.search.click(RowID(path: "b.txt", match: 0))
    XCTAssertEqual(editor.documents.map(\.url.lastPathComponent), ["b.txt"], "仮のタブが入れ替わる")
    XCTAssertTrue(editor.preview === hosted.pane.document)

    hosted.search.doubleClick(RowID(path: "b.txt", match: 0))
    XCTAssertNil(editor.preview, "ダブルクリックで普通のタブ")
    hosted.search.click(RowID(path: "c.txt", match: 0))
    XCTAssertEqual(editor.documents.map(\.url.lastPathComponent), ["b.txt", "c.txt"])
    XCTAssertTrue(editor.preview === hosted.pane.document)
  }

  /// ↓ を押して離した直後に焦点を本文・端末へ移しても、遅れて走る開きは開くだけで焦点を結果へ引き戻さない。
  func testADelayedArrowOpenLeavesTheFocusWhereItIs() throws {
    let hosted = try host(["a.txt": "needle\nneedle\n"])
    searchAll(hosted, "needle")
    let list = try list(hosted)
    let down = NSEvent.key(String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!), [])
    let moves: [(String, () -> Void)] = [
      ("本文", { hosted.window.makeFirstResponder(hosted.pane.document?.surface.responder) }),
      ("面の外", { hosted.window.makeFirstResponder(nil) }),
    ]
    for (name, move) in moves {
      hosted.window.makeFirstResponder(list)
      hosted.search.select(RowID(path: "a.txt", match: nil))
      RunLoop.main.run(until: Date().addingTimeInterval(ProjectSearch.navigationWindow * 2))
      list.keyDown(with: down)
      XCTAssertEqual(hosted.pane.document?.surface.selectedRange, NSRange(location: 0, length: 6))
      list.keyDown(with: down)  // 窓の中: 待つ
      move()
      let responder = hosted.window.firstResponder
      pumpMain(
        until: { hosted.pane.document?.surface.selectedRange == NSRange(location: 7, length: 6) },
        "\(name): 窓が閉じたら最後の選択を開く")
      XCTAssertTrue(
        holds(for: ProjectSearch.navigationWindow * 2) {
          hosted.window.firstResponder === responder
        },
        "\(name): 焦点は動かない")
    }
  }

  /// レールの「検索」は検索パネルへ切り替えて入力欄に焦点を入れ、出しているときに押すと閉じる。
  func testTheRailsSearchItemShowsThePanelWithTheFieldFocused() throws {
    let hosted = try host(["a.txt": "needle\n"])
    hosted.pane.shell.selectPanel(.search)
    XCTAssertTrue(hosted.pane.showsSearchPanel)
    pumpMain(until: { hosted.search.focusedArea == .field }, "入力欄に焦点")

    hosted.pane.shell.selectPanel(.search)
    XCTAssertFalse(hosted.pane.sidebar.isOpen)
  }

  /// 焦点がパネルにあるままパネルを隠すと、焦点は本文へ戻る。
  func testHidingThePanelReturnsItsFocusToTheText() throws {
    let hosted = try host(["a.txt": "needle\n"])
    _ = try open(hosted, "a.txt")
    searchAll(hosted, "needle")
    pumpMain(until: { hosted.search.focusedArea == .field })

    hosted.pane.sidebar.select(.files)
    pumpMain(until: { textHasFocus(hosted) }, "本文へ戻る")
  }

  /// 焦点を入れる要求はその場の 1 回きり——パネルが後で現れても、F4 で本文へ移した焦点を奪わない。
  func testAFocusRequestIsNotReplayedWhenThePanelReappears() throws {
    let hosted = try host(["a.txt": "needle\n"])
    _ = try open(hosted, "a.txt")
    searchAll(hosted, "needle")
    pumpMain(until: { hosted.search.focusedArea == .field })
    hosted.pane.sidebar.select(.files)
    pumpMain(until: { textHasFocus(hosted) })

    XCTAssertTrue(hosted.pane.handleStepKey(f4))
    XCTAssertTrue(holds(for: 0.3) { textHasFocus(hosted) }, "現れたパネルが焦点を奪わない")
  }

  // MARK: - 根の変化

  /// cd で根が変わると結果を捨て、検索パネルが画面に見えている面だけが今の問いで探し直す。
  func testChangingTheRootSearchesAgainOnlyWhileThePanelIsSeen() throws {
    let hosted = try host(["a.txt": "needle\n"])
    let other = try TempGitRepo(name: "orbe-search-pane-other")
    addTeardownBlock { other.cleanup() }
    try other.write("m.txt", "needle\n")
    searchAll(hosted, "needle")

    hosted.pane.isHidden = true
    hosted.pane.setRoot(other.root)
    XCTAssertEqual(hosted.search.phase, .idle, "見えていない面では探さない")
    XCTAssertTrue(hosted.search.results.isEmpty)

    hosted.pane.isHidden = false
    hosted.pane.setRoot(hosted.repo.root)
    pumpMain(until: { hosted.search.phase == .done }, "見えている面は探し直す")
    XCTAssertEqual(hosted.search.results.files.map(\.path), ["a.txt"])
  }
}
