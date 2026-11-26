import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 面の結線——一致の地は検索パネルが見えている間だけ ⌘F の一致との和で本文と俯瞰に出る、パネルの中のキー（⌥⌘C / W / R・
/// ⌘↓ / ⌘↑）、エディター面の F4 / ⇧F4、ほかの画面・閉じた左の列からの ⌘⇧F、開き方と焦点（シングルクリックは仮の文書として
/// 結果に残り、ダブルクリック・Enter は普通の文書として本文へ、一致は中央へ）、パネルを隠すと焦点は本文へ戻り、焦点の要求は
/// 後で奪わない、裏のタブの cd では探さない。
///
/// 壊れると何が起きるか。パネルを隠しても地が残る、⌘F の地が消える。パネルのキーが効かない、本文の打鍵を奪う。端末の F4 が
/// 奪われる、本文の F4 が効かない。左の列を閉じている・Changes や PR の画面に居ると、⌘⇧F を押しても入力欄が出ない。
/// クリックで渡るたびに焦点が本文へ飛ぶ、開いている文書が増える。隠れたパネルに焦点が取り残されて打鍵が消える。見ていないタブが cd の
/// たびに根の全体を探す。
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

    hosted.pane.filesPanel = .files
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
    pane.filesPanel = .files
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
    hosted.search.setPattern("")
    XCTAssertFalse(pane.handleStepKey(f4), "結果が無ければ素通し")
  }

  /// ⌘⇧F は、ほかの画面に居ても左の列を閉じていても、Files の画面にして左の列を検索パネルで開き、入力欄に焦点を入れる。
  func testFindInProjectFromAnotherScreenWithTheSidebarClosedFocusesTheSearchField() throws {
    let hosted = try host(["a.txt": "needle\n"])
    let pane = hosted.pane
    pane.switchScreen(.changes)
    pane.toggleSidebar()

    pane.showProjectSearch(seed: nil)
    XCTAssertEqual(
      hosted.search.focusRequest, .field,
      "⌘⇧F は、その場で入力欄への焦点を求める。"
        + "これが待たずに成り立たなくなれば、testAFocusRequestIsNotReplayedWhenThePanelReappears の確かめる時点も成り立たない")
    XCTAssertEqual(hosted.tab.group.editor.screen, .files)
    XCTAssertTrue(pane.showsSearchPanel, "左の列を検索パネルで開く")
    pumpMain(
      until: { hosted.search.focusedArea == .field && pane.focusIsInSidebar }, "入力欄に焦点")
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
      let first = CGFloat(viewport.top.line)
      XCTAssertEqual(
        first + viewport.visibleLines / 2, CGFloat(line) + 0.5, accuracy: 1,
        "一致の行が中央へ（見えていても）")
      XCTAssertTrue(hosted.pane.focusIsInSidebar, "シングルクリックは焦点を結果に残す")
    }

    hosted.search.doubleClick(RowID(path: "long.txt", match: 0))
    XCTAssertTrue(textHasFocus(hosted), "ダブルクリックは本文へ")
  }

  /// 一致のクリックは仮の文書として開き、次のクリックがその仮の文書を入れ替える（開いている文書が増えない）。ダブルクリックは
  /// 普通の文書にし、次のクリックは別の仮の文書として列の先頭に開く。
  func testClickingMatchesBrowsesInOnePreviewTab() throws {
    let hosted = try host(["a.txt": "needle\n", "b.txt": "needle\n", "c.txt": "needle\n"])
    searchAll(hosted, "needle")
    let editor = hosted.tab.group.editor

    hosted.search.click(RowID(path: "a.txt", match: 0))
    hosted.search.click(RowID(path: "b.txt", match: 0))
    XCTAssertEqual(editor.documents.map(\.url.lastPathComponent), ["b.txt"], "仮の文書が入れ替わる")
    XCTAssertTrue(editor.preview === hosted.pane.document)

    hosted.search.doubleClick(RowID(path: "b.txt", match: 0))
    XCTAssertNil(editor.preview, "ダブルクリックで普通の文書")
    hosted.search.click(RowID(path: "c.txt", match: 0))
    XCTAssertEqual(editor.documents.map(\.url.lastPathComponent), ["c.txt", "b.txt"])
    XCTAssertTrue(editor.preview === hosted.pane.document)
  }

  // MARK: - 検索パネルを離れる

  /// 入力欄の Esc（窓が配るキー）で、左の列はエクスプローラーへ戻り、焦点は本文へ移る。変換中の Esc（変換の取り消し）と
  /// キーリピートの Esc では戻らない。
  func testEscapeInTheFieldLeavesForTheExplorerButNotWhileComposingOrRepeating() throws {
    let hosted = try host(["a.txt": "needle\n"])
    _ = try open(hosted, "a.txt")
    searchAll(hosted, "needle")
    pumpMain(until: { hosted.search.focusedArea == .field }, "入力欄に焦点")
    let field = try XCTUnwrap(hosted.window.firstResponder as? NSTextView)
    let end = NSRange(location: field.string.utf16.count, length: 0)
    field.setSelectedRange(end)

    // 入力欄に変換中の字を置く（IME の打鍵と同じ口）。
    field.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: end)
    deliverKeyDown(.key("\u{1b}", []), to: hosted.window)
    flush(hosted.window)
    XCTAssertTrue(hosted.pane.showsSearchPanel, "変換中の Esc では戻らない")
    field.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: end)

    deliverKeyDown(.key("\u{1b}", [], isRepeat: true), to: hosted.window)
    flush(hosted.window)
    XCTAssertTrue(hosted.pane.showsSearchPanel, "キーリピートの Esc では戻らない")

    deliverKeyDown(.key("\u{1b}", []), to: hosted.window)
    flush(hosted.window)
    XCTAssertFalse(hosted.pane.showsSearchPanel, "エクスプローラーへ戻る")
    XCTAssertEqual(hosted.tab.group.editor.screen, .files)
    pumpMain(until: { textHasFocus(hosted) }, "焦点は本文へ")
  }

  /// 焦点が検索パネルの外（ファイル内検索の欄）にあるまま、見出しの「ツリーに戻る」のボタンを押して検索パネルを離れても、焦点は
  /// 動かない。
  func testLeavingWithTheFocusOutsideThePanelKeepsTheFocus() throws {
    let hosted = try host(["a.txt": "needle\n"])
    _ = try open(hosted, "a.txt")
    searchAll(hosted, "needle")
    hosted.pane.showSearch()
    XCTAssertNotNil(hosted.pane.findField.model)
    func fieldHasFocus() -> Bool {
      (hosted.window.firstResponder as? NSView)?.isDescendant(of: hosted.pane.barHost) == true
    }
    pumpMain(until: fieldHasFocus, "前提: ファイル内検索の欄に焦点")

    hosted.search.dismiss()
    XCTAssertFalse(hosted.pane.showsSearchPanel)
    pumpMain(until: { hosted.pane.searchResults.window == nil }, "検索パネルが窓から外れる")
    XCTAssertTrue(fieldHasFocus(), "焦点はファイル内検索の欄のまま")
  }

  /// 焦点を入れる要求はその場の 1 回きり——パネルが後で現れても、F4 で本文へ移した焦点を奪わない。
  ///
  /// 焦点を奪わないことは、パネルが窓に載ったのを待った時点で確かめる。前提は、パネルの中へ焦点を入れる経路が、どれも走る時点で
  /// 焦点の要求（`focusRequest`）を見直すことと、要求を出すのが明示の呼び出しだけであること。再び表示されたパネルが要求を経ずに
  /// 入力欄へ焦点を入れるようにすると、このテストが落ちることを確かめてある。焦点を入れる経路か、要求を出す経路を変えたときは、
  /// 確かめ直す。
  func testAFocusRequestIsNotReplayedWhenThePanelReappears() throws {
    let hosted = try host(["a.txt": "needle\n"])
    _ = try open(hosted, "a.txt")
    searchAll(hosted, "needle")
    pumpMain(until: { hosted.search.focusedArea == .field })
    hosted.pane.filesPanel = .files
    pumpMain(until: { textHasFocus(hosted) })

    XCTAssertTrue(hosted.pane.handleStepKey(f4))
    pumpMain(until: { hosted.pane.searchResults.window != nil }, "F4 でパネルが再び表示される")
    XCTAssertNil(hosted.search.focusRequest, "現れたパネルに、焦点を入れる要求は残っていない")
    XCTAssertTrue(textHasFocus(hosted), "現れたパネルが焦点を奪わない")
  }

  // MARK: - 根の変化

  /// cd で根が変わると結果を捨て、検索パネルが画面に見えている面だけが今の問いで探し直す。
  func testChangingTheRootSearchesAgainOnlyWhileThePanelIsSeen() throws {
    let hosted = try host(["a.txt": "needle\n"])
    let other = try TempGitRepo(name: "orbe-search-pane-other")
    try other.write("m.txt", "needle\n")
    searchAll(hosted, "needle")

    hosted.pane.isHidden = true
    hosted.tab.group.rekey(other.root)
    XCTAssertEqual(hosted.search.phase, .idle, "見えていない面では探さない")
    XCTAssertTrue(hosted.search.results.isEmpty)

    hosted.pane.isHidden = false
    hosted.tab.group.rekey(hosted.repo.root)
    pumpMain(until: { hosted.search.phase == .done }, "見えている面は探し直す")
    XCTAssertEqual(hosted.search.results.files.map(\.path), ["a.txt"])
  }
}
