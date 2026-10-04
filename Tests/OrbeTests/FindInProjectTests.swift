import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// ⌘⇧F と面の焦点の記憶——⌘⇧F は端末焦点からでもエディターを見せ（隠れていれば全面、分割中は焦点だけ）、検索パネルの入力欄に
/// 焦点を入れる。種は押した時点の焦点で決まる（本文の 1 行以内の選択・⌘F のバーの検索語。端末・検索パネル・キャレットだけ・
/// 複数行は種にしない）。焦点がどの経路で面に入っても（検索パネルの入力欄を直接クリックしても）面の記憶はその面へ移る。
///
/// 壊れると何が起きるか。端末で ⌘⇧F を押しても入力欄へ届かない、分割が全面に潰れる。見ていない文書の古い選択や複数行が
/// 検索語に入る。分割中に端末から入力欄を直接クリックすると位置ドットと現在地が端末を指したまま、⌘E が本文へ飛ぶ。
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

  func testFindInProjectShowsTheWholeEditorWithTheSearchFieldFocused() throws {
    let wc = windowController()
    let tab = try XCTUnwrap(wc.activeTab)
    let pane = tab.view.editor

    wc.handleWindowCommand(.findInProject)
    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 1, focus: .editor), "隠れていれば全面")
    XCTAssertTrue(pane.showsSearchPanel)
    pumpMain(until: { searchFieldIsFocused(pane) }, "入力欄に焦点")
  }

  func testFindInProjectWhileSplitOnlyMovesFocus() throws {
    let wc = windowController()
    let tab = try XCTUnwrap(wc.activeTab)
    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)

    wc.handleWindowCommand(.findInProject)
    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 0.5, focus: .editor), "分割は保つ")
    pumpMain(until: { searchFieldIsFocused(tab.view.editor) }, "入力欄に焦点")
  }

  func testFindInProjectWithoutTabsDoesNothing() throws {
    let wc = windowController()
    wc.closeTab(try XCTUnwrap(wc.activeTab), origin: .gesture)
    XCTAssertNil(wc.activeTab, "前提: 0 タブ")

    wc.handleWindowCommand(.findInProject)
    XCTAssertNil(wc.activeTab)
  }

  // MARK: - 面の焦点の記憶

  /// 分割中に端末から検索パネルの入力欄を直接クリックしても、面の記憶はエディターへ移り、焦点は入力欄に残る。
  func testFocusEnteringTheSearchFieldDirectlyMovesTheFaceMemory() throws {
    let wc = windowController()
    let tab = try XCTUnwrap(wc.activeTab)
    let pane = tab.view.editor
    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    wc.window.contentView?.layoutSubtreeIfNeeded()
    pane.sidebar.show(.search)
    pumpMain(until: { textField(in: pane.sideHost) != nil }, "入力欄が出る")
    XCTAssertTrue(wc.window.firstResponder === tab.surface, "前提: 端末に焦点")

    wc.window.makeFirstResponder(try XCTUnwrap(textField(in: pane.sideHost)))
    XCTAssertEqual(tab.faces.focus, .editor, "面の記憶がエディターへ")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    XCTAssertTrue(pane.focusIsInSidebar, "焦点は入力欄に残る（本文へ奪わない）")

    wc.window.makeFirstResponder(tab.surface)
    XCTAssertEqual(tab.faces.focus, .terminal, "端末へ戻れば記憶も端末へ")
  }

  private func textField(in view: NSView) -> NSTextField? {
    for subview in view.subviews {
      if let field = subview as? NSTextField, field.isEditable { return field }
      if let field = textField(in: subview) { return field }
    }
    return nil
  }

  // MARK: - 種

  /// タブを窓に載せ、文書を開いて本文に焦点を置く。
  private struct Hosted {
    let tab: TerminalTab
    let document: EditorDocument
    let window: NSWindow
  }

  private func hostWithDocument(_ text: String) throws -> Hosted {
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900)
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    let document = try tab.editor.open(try caseFile("seed.txt", text), as: .pinned)
    tab.view.editor.layoutSubtreeIfNeeded()
    window.makeFirstResponder(document.surface.responder)
    tab.view.editor.projectSearch.restore(SearchQuery(pattern: "previous"))
    return Hosted(tab: tab, document: document, window: window)
  }

  /// 本文の 1 行以内の選択が種になる（正規表現が有効なら字どおりになるようエスケープする）。
  func testTheSelectionInTheTextSeedsTheSearch() throws {
    let hosted = try hostWithDocument("foo.bar\nnext\n")
    let (tab, document) = (hosted.tab, hosted.document)
    let search = tab.view.editor.projectSearch
    document.surface.selectedRange = NSRange(location: 0, length: 7)
    tab.findInProject()
    XCTAssertEqual(search.query.pattern, "foo.bar")
    XCTAssertNotEqual(search.phase, .idle, "種を入れたら即時に探す")

    search.toggle(.regex)
    tab.view.window?.makeFirstResponder(document.surface.responder)
    tab.findInProject()
    XCTAssertEqual(search.query.pattern, #"foo\.bar"#)
  }

  /// キャレットだけ・複数行の選択は種にしない（前の検索語のまま）。
  func testACaretOrAMultiLineSelectionDoesNotSeed() throws {
    let hosted = try hostWithDocument("foo\nbar\n")
    let (tab, document, window) = (hosted.tab, hosted.document, hosted.window)
    let search = tab.view.editor.projectSearch
    document.surface.selectedRange = NSRange(location: 1, length: 0)
    tab.findInProject()
    XCTAssertEqual(search.query.pattern, "previous", "キャレットの語は使わない")

    window.makeFirstResponder(document.surface.responder)
    document.surface.selectedRange = NSRange(location: 0, length: 6)
    tab.findInProject()
    XCTAssertEqual(search.query.pattern, "previous", "複数行は種にしない")
  }

  func testTheFindBarsNeedleSeedsTheSearch() throws {
    let hosted = try hostWithDocument("foo\n")
    let (tab, window) = (hosted.tab, hosted.window)
    let pane = tab.view.editor
    pane.showSearch()
    let bar = try XCTUnwrap(pane.searchBar)
    bar.onNeedleChange?("oo")
    pumpMain(until: { (window.firstResponder as? NSView)?.isDescendant(of: bar) == true })

    tab.findInProject()
    XCTAssertEqual(pane.projectSearch.query.pattern, "oo")
  }

  /// 入力欄に焦点があるまま ⌘⇧F を押し直しても、検索語を全選択に戻す（VS Code と同じ。打てば置き換わる）。
  func testFindInProjectAgainSelectsTheWholePattern() throws {
    let hosted = try hostWithDocument("foo\n")
    let (tab, window) = (hosted.tab, hosted.window)
    tab.findInProject()
    pumpMain(until: { searchFieldIsFocused(tab.view.editor) }, "入力欄に焦点")
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    pumpMain(until: { editor.string == "previous" }, "入力欄に前の検索語")
    editor.setSelectedRange(NSRange(location: 3, length: 0))

    tab.findInProject()
    XCTAssertTrue(window.firstResponder === editor, "焦点は入力欄のまま")
    XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 8))
  }

  /// 焦点が端末か検索パネルにあれば、本文に選択があっても種にしない。
  func testNoSeedFromTheTerminalOrFromTheSearchPanel() throws {
    let hosted = try hostWithDocument("foo\n")
    let (tab, document, window) = (hosted.tab, hosted.document, hosted.window)
    let search = tab.view.editor.projectSearch
    document.surface.selectedRange = NSRange(location: 0, length: 3)
    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    window.makeFirstResponder(tab.surface)
    tab.findInProject()
    XCTAssertEqual(search.query.pattern, "previous", "端末の焦点からは種にしない")

    pumpMain(until: { searchFieldIsFocused(tab.view.editor) }, "入力欄に焦点")
    tab.findInProject()
    XCTAssertEqual(search.query.pattern, "previous", "検索パネルの焦点からは種にしない")
  }
}
