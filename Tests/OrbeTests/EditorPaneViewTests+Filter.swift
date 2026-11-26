import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// エクスプローラーの絞り込みの欄を本物の入力欄（SwiftUI の TextField）で駆動する: 欄と行内入力の焦点の行き来、欄の esc、
/// エクスプローラーが隠れたときの焦点の戻し、結果がファイルの増減に追従し、隠れていた間の増減には、出し直したときに追いつくこと。
///
/// 壊れると何が起きるか。新規ファイルの入力の途中で欄を押すと、入力が残る・焦点が本文へ奪われて打鍵が本文に入る。欄から新規
/// ファイルを押しても、入力行が出ない・打鍵が欄に入る。左の列を閉じた後も焦点が見えない欄に残り、打鍵と ⌘S が届かない。
/// 絞り込んだまま足したファイルが、絞り込みを打ち直すまで出ない。日本語で絞り込む途中の esc で、変換を取り消すつもりが字ごと消える。
@MainActor
final class EditorPaneViewFilterTests: OrbeTestCase {
  private struct Hosted {
    let tab: TerminalTab
    let window: NSWindow
    /// 本文の焦点の行き先（開いた a.txt のテキスト面）。
    let body: NSResponder
    @MainActor var pane: EditorPaneView { tab.group.view.editor }
    @MainActor var tree: FileTree { pane.tree }
  }

  /// 根に a.txt・readme.md を置き、a.txt を開いた幅 900 の面（エクスプローラーを出す）。窓は並べない。
  private func host() throws -> Hosted {
    let a = try caseFile("a.txt", "a")
    _ = try caseFile("readme.md", "r")
    let tab = TerminalTab.alone(
      cwd: TestScratch.caseDir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900)
    let document = try tab.group.editor.open(a, as: .pinned)
    pumpMain(
      until: { tab.group.view.editor.tree.rows.contains { $0.name == "readme.md" } }, "ファイルの行が出る")
    return Hosted(tab: tab, window: window, body: document.surface.responder)
  }

  /// 絞り込みの欄を押す（窓は `placeOffscreen` で並べておくこと）。
  private func pressField(_ hosted: Hosted) throws {
    try click(
      hosted.pane,
      at: NSPoint(
        x: hosted.pane.sideHost.frame.minX + Theme.Layout.editorTreeTopPad + 40,
        y: Theme.Layout.editorBar + Theme.Layout.editorTreeTopPad + Theme.Layout.editorTreeField / 2
      ))
  }

  private func escape(in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
  }

  private func focusIsInSidebar(_ hosted: Hosted) -> Bool {
    (hosted.window.firstResponder as? NSView)?.isDescendant(of: hosted.pane.sideHost) == true
  }

  /// 新規ファイルの入力の途中で欄を押すと、入力は取り消され、焦点は欄に残る（本文へ奪われず、打鍵は欄に入る）。
  func testPressingTheFieldDuringAnInlineInputCancelsItAndKeepsTheFocusInTheField() throws {
    let hosted = try host()
    placeOffscreen(hosted.window)
    hosted.pane.shell.createFile()
    let input = try inputField(hosted.pane, in: hosted.window)
    input.insertText("draft", replacementRange: NSRange(location: 0, length: 0))

    try pressField(hosted)
    pumpMain(until: { hosted.tree.newEntry == nil }, "入力は取り消される")
    flush(hosted.window)

    let field = try inputField(hosted.pane, in: hosted.window)
    field.insertText("read", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(hosted.tree.filter.text, "read", "打鍵は欄に入る")
  }

  /// 欄に焦点があり字があるときに新規ファイルを押すと、絞り込みが解けて入力行が出て、焦点は入力行に入る。
  func testNewFileFromTheFieldClearsTheFilterAndFocusesTheInputRow() throws {
    let hosted = try host()
    placeOffscreen(hosted.window)
    try pressField(hosted)
    try inputField(hosted.pane, in: hosted.window)
      .insertText("read", replacementRange: NSRange(location: 0, length: 0))
    pumpMain(until: { hosted.tree.filter.shown?.text == "read" }, "前提: 絞り込んでいる")

    hosted.pane.shell.createFile()
    XCTAssertEqual(hosted.tree.filter.text, "", "絞り込みが解ける")
    XCTAssertTrue(hosted.tree.rows.contains(where: \.isInput), "入力行が出る")

    let input = try inputField(hosted.pane, in: hosted.window)
    input.insertText("new.txt", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertEqual(hosted.tree.newEntry?.name, "new.txt", "打鍵は入力行に入る")
    XCTAssertEqual(hosted.tree.filter.text, "")
  }

  /// 欄の esc は、字があれば字を消し（絞り込みが解け、焦点は欄のまま）、空なら本文へ焦点を移す。変換中の esc では、欄は
  /// 絞り込みの字を消さず、変換中の字にも触れない（変換の取り消しは IME が行う）。
  func testEscapeInTheFieldClearsTheTextAndThenMovesTheFocusToTheBody() throws {
    let hosted = try host()
    placeOffscreen(hosted.window)
    try pressField(hosted)
    let field = try inputField(hosted.pane, in: hosted.window)
    field.insertText("read", replacementRange: NSRange(location: 0, length: 0))

    // 欄に変換中の字を置く（IME の打鍵と同じ口）。
    let end = NSRange(location: field.string.utf16.count, length: 0)
    field.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: end)
    deliverKeyDown(escape(in: hosted.window), to: hosted.window)
    XCTAssertEqual(hosted.tree.filter.text, "read", "変換中の esc では絞り込みの字は消えない")
    XCTAssertTrue(field.hasMarkedText(), "欄は変換中の字に触れない")
    field.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: end)

    // 変換中の esc の確かめと対にするため、字が消えることも、esc を送った直後に確かめる（消えるのを待たない）。
    deliverKeyDown(escape(in: hosted.window), to: hosted.window)
    XCTAssertEqual(hosted.tree.filter.text, "", "字を消す")
    flush(hosted.window)
    XCTAssertTrue(focusIsInSidebar(hosted), "焦点は欄のまま")

    deliverKeyDown(escape(in: hosted.window), to: hosted.window)
    pumpMain(until: { hosted.window.firstResponder === hosted.body }, "空の欄の esc で本文へ")
  }

  /// 欄に焦点があるまま、左の列を閉じる・画面を切り替える・検索パネルへ替えると、焦点は本体の焦点の行き先（Files なら開いている
  /// 文書のテキスト面、文書の無い Changes なら面自身）へ移る。
  func testHidingTheExplorerMovesTheFocusFromTheFieldToTheBody() throws {
    let hosted = try host()
    placeOffscreen(hosted.window)
    let pane = hosted.pane
    func check(
      _ label: String, to body: NSResponder, hide: () -> Void, show: () -> Void
    ) throws {
      try pressField(hosted)
      _ = try inputField(pane, in: hosted.window)
      flush(hosted.window)

      hide()
      pumpMain(until: { hosted.window.firstResponder === body }, "\(label): 焦点は本体の焦点の行き先へ")

      show()
      flush(hosted.window)
    }
    try check("左の列を閉じる", to: hosted.body, hide: pane.toggleSidebar, show: pane.toggleSidebar)
    try check("画面を切り替える", to: pane) {
      pane.switchScreen(.changes)
    } show: {
      pane.switchScreen(.files)
    }
    try check("検索パネルへ替える", to: hosted.body) {
      pane.filesPanel = .search
    } show: {
      pane.filesPanel = .files
    }
  }

  /// 絞り込みの結果は、ファイルの増減に追従する。左の列を閉じている間の増減には、開き直したときに追いつく。
  func testResultsFollowFileChangesAndCatchUpWhenTheExplorerIsShownAgain() throws {
    let hosted = try host()
    let tree = hosted.tree
    tree.setFilterText("note")
    pumpMain(until: { tree.filter.shown?.text == "note" }, "前提: 結果が届く")

    _ = try caseFile("note1.txt", "1")
    pumpMain(until: { tree.rows.contains { $0.name == "note1.txt" } }, "増えたファイルが結果に出る")

    hosted.pane.toggleSidebar()
    flush(hosted.window)
    _ = try caseFile("note2.txt", "2")
    pumpMain(
      until: { tree.entries[""]?.contains { $0.name == "note2.txt" } == true },
      "前提: 閉じている間の変化がツリーに届く")
    hosted.pane.toggleSidebar()

    pumpMain(until: { tree.rows.contains { $0.name == "note2.txt" } }, "開き直すと追いつく")
  }
}
