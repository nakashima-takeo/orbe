import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe

/// ⌘⇧F——端末からでもエディターを開き（閉じていれば開く）、検索パネルの入力欄に焦点を入れる。開いたまま押し直しても焦点は
/// 入力欄に残る。種は押した時点の焦点で決まる（本文の 1 行以内の選択・ファイル内検索の欄の検索語。端末・検索パネル・キャレットだけ・
/// 複数行は種にしない）。
///
/// 壊れると何が起きるか。端末で ⌘⇧F を押しても入力欄へ届かない。入力欄に打っている途中で押し直すと焦点が本文へ奪われる。
/// 見ていない文書の古い選択や複数行が検索語に入る。
@MainActor
final class FindInProjectTests: OrbeTestCase {
  /// 実窓に WindowController を繋ぐ（libghostty ランタイムを起動する）。言語は選択済みにして初回の言語画面を出さない。
  private func windowController() -> WindowController {
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    return WindowController()
  }

  private func searchFieldIsFocused(_ pane: EditorPaneView) -> Bool {
    pane.projectSearch.focusedArea == .field && pane.focusIsInSidebar
  }

  // MARK: - ⌘⇧F

  func testFindInProjectOpensTheEditorWithTheSearchFieldFocused() throws {
    let wc = windowController()
    let tab = try XCTUnwrap(wc.activeTab)
    let pane = tab.group.view.editor

    wc.handleWindowCommand(.findInProject)
    XCTAssertTrue(tab.group.view.isEditorOpen, "閉じていれば開く")
    XCTAssertTrue(pane.showsSearchPanel)
    pumpMain(until: { searchFieldIsFocused(pane) }, "入力欄に焦点")
  }

  func testFindInProjectWithoutTabsDoesNothing() throws {
    let wc = windowController()
    wc.closeTab(try XCTUnwrap(wc.activeTab), origin: .gesture)
    XCTAssertNil(wc.activeTab, "前提: 0 タブ")

    wc.handleWindowCommand(.findInProject)
    XCTAssertNil(wc.activeTab)
  }

  // MARK: - 種

  /// 実窓でエディターを開き、文書を開いて本文に焦点を置く。
  private struct Hosted {
    let wc: WindowController
    let tab: TerminalTab
    let document: EditorDocument
    var window: NSWindow { wc.window }

    func findInProject() { wc.handleWindowCommand(.findInProject) }
  }

  private func hostWithDocument(_ text: String) throws -> Hosted {
    let wc = windowController()
    let tab = try XCTUnwrap(wc.activeTab)
    let document = try tab.group.editor.open(try caseFile("seed.txt", text), as: .pinned)
    wc.handleWindowCommand(.toggleEditorFace)
    wc.window.contentView?.layoutSubtreeIfNeeded()
    wc.window.makeFirstResponder(document.surface.responder)
    tab.group.view.editor.projectSearch.restore(SearchQuery(pattern: "previous"))
    return Hosted(wc: wc, tab: tab, document: document)
  }

  /// 本文の 1 行以内の選択が種になる（正規表現が有効なら字どおりになるようエスケープする）。
  func testTheSelectionInTheTextSeedsTheSearch() throws {
    let hosted = try hostWithDocument("foo.bar\nnext\n")
    let (tab, document) = (hosted.tab, hosted.document)
    let search = tab.group.view.editor.projectSearch
    document.surface.selectedRange = NSRange(location: 0, length: 7)
    hosted.findInProject()
    XCTAssertEqual(search.query.pattern, "foo.bar")
    XCTAssertNotEqual(search.phase, .idle, "種を入れたら即時に探す")

    search.toggle(.regex)
    hosted.window.makeFirstResponder(document.surface.responder)
    hosted.findInProject()
    XCTAssertEqual(search.query.pattern, #"foo\.bar"#)
  }

  /// キャレットだけ・複数行の選択は種にしない（前の検索語のまま）。
  func testACaretOrAMultiLineSelectionDoesNotSeed() throws {
    let hosted = try hostWithDocument("foo\nbar\n")
    let (tab, document, window) = (hosted.tab, hosted.document, hosted.window)
    let search = tab.group.view.editor.projectSearch
    document.surface.selectedRange = NSRange(location: 1, length: 0)
    hosted.findInProject()
    XCTAssertEqual(search.query.pattern, "previous", "キャレットの語は使わない")

    window.makeFirstResponder(document.surface.responder)
    document.surface.selectedRange = NSRange(location: 0, length: 6)
    hosted.findInProject()
    XCTAssertEqual(search.query.pattern, "previous", "複数行は種にしない")
  }

  func testTheFindBarsNeedleSeedsTheSearch() throws {
    let hosted = try hostWithDocument("foo\n")
    let (tab, window) = (hosted.tab, hosted.window)
    let pane = tab.group.view.editor
    pane.showSearch()
    let field = try XCTUnwrap(pane.findField.model)
    field.onNeedleChange?("oo")
    pumpMain(until: { (window.firstResponder as? NSView)?.isDescendant(of: pane.barHost) == true })

    hosted.findInProject()
    XCTAssertEqual(pane.projectSearch.query.pattern, "oo")
  }

  /// 入力欄に打っている途中で ⌘⇧F を押し直しても、焦点は入力欄に残り（開いていれば描き直さない）、検索語を全選択に
  /// 戻す（VS Code と同じ。打てば置き換わる）。
  func testFindInProjectAgainKeepsTheFieldFocusedAndSelectsTheWholePattern() throws {
    let hosted = try hostWithDocument("foo\n")
    let (tab, window) = (hosted.tab, hosted.window)
    hosted.findInProject()
    pumpMain(until: { searchFieldIsFocused(tab.group.view.editor) }, "入力欄に焦点")
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    pumpMain(until: { editor.string == "previous" }, "入力欄に前の検索語")
    editor.setSelectedRange(NSRange(location: 3, length: 0))

    hosted.findInProject()
    pumpMain(until: { tab.group.view.editor.projectSearch.focusRequest == nil }, "焦点の要求が消費される")
    XCTAssertTrue(holds(for: 0.1) { window.firstResponder === editor }, "焦点は入力欄のまま")
    XCTAssertEqual(
      editor.selectedRange(), NSRange(location: 0, length: 8), "焦点が当たった後も、検索語の全体が選ばれている")
  }

  /// 焦点が端末か検索パネルにあれば、本文に選択があっても種にしない。
  func testNoSeedFromTheTerminalOrFromTheSearchPanel() throws {
    let hosted = try hostWithDocument("foo\n")
    let (tab, document, window) = (hosted.tab, hosted.document, hosted.window)
    let search = tab.group.view.editor.projectSearch
    document.surface.selectedRange = NSRange(location: 0, length: 3)
    hosted.wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertTrue(window.firstResponder === tab.surface, "前提: 閉じて端末に焦点")
    hosted.findInProject()
    XCTAssertEqual(search.query.pattern, "previous", "端末の焦点からは種にしない")

    pumpMain(until: { searchFieldIsFocused(tab.group.view.editor) }, "入力欄に焦点")
    hosted.findInProject()
    XCTAssertEqual(search.query.pattern, "previous", "検索パネルの焦点からは種にしない")
  }
}
