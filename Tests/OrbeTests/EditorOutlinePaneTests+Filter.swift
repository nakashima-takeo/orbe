import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 打鍵で絞り込む——列で打った字から入力欄が受け、一致が選ばれ、入力欄の ↑↓・Enter・Esc は行の操作になる。絞り込んで
/// いる間は全部を開いた別の畳みを使う。
extension EditorOutlinePaneTests {
  /// 列で打った字から絞り込み、入力欄の ↓ と Enter は行の操作になり、Esc で解いて列へ戻る。
  func testTypingInTheListFilters() throws {
    let hosted = try host()
    openOutline(hosted)
    let outline = hosted.pane.outline
    let container = hosted.pane.outlineList
    let list = container.scrollView.list
    hosted.window.makeFirstResponder(list)

    list.keyDown(with: .key("f", []))
    XCTAssertTrue(outline.isFilterShown)
    XCTAssertEqual(container.field.text, "f", "最初の字は入力欄が受ける")
    catchUp(hosted.document)
    pumpMain(
      until: { self.names(outline) == ["Channel", "  buffer", "  flush()"] },
      "一致とその祖先だけが残る（VS Code の tree と同じく語の途中の字にも当たる）")
    XCTAssertEqual(outline.row(at: 1).matches, [2..<3])
    XCTAssertEqual(outline.row(at: 2).matches, [0..<1])

    XCTAssertEqual(outline.selectedRow, 1, "前提: 最初の一致が選ばれる")
    let editor = try XCTUnwrap(container.field.textField.currentEditor())
    editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
    XCTAssertEqual(outline.selectedRow, 2, "入力欄の ↓ は行を選ぶ")
    editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertFalse(outline.isFilterShown)
    catchUp(hosted.document)
    pumpMain(until: { outline.rowCount == 6 }, "Esc で絞り込みを解く")
    XCTAssertTrue(hosted.window.firstResponder === list, "Esc で列へ戻る")
  }

  /// 打った字で絞り込むと一致した行が選ばれ（祖先として残っただけの行ではなく）、字を足しても一致が選ばれたまま、
  /// 入力欄の Enter でその一致へ飛ぶ。Esc で解いても選択は残る。
  func testTypingSelectsAMatchAndEnterJumpsToIt() throws {
    let hosted = try host()
    openOutline(hosted)
    let outline = hosted.pane.outline
    let container = hosted.pane.outlineList
    let list = container.scrollView.list
    hosted.window.makeFirstResponder(list)
    let selected = { outline.selectedRow.map { outline.row(at: $0).name } }

    list.keyDown(with: .key("f", []))
    catchUp(hosted.document)
    pumpMain(until: { self.names(outline) == ["Channel", "  buffer", "  flush()"] }, "絞り込む")
    XCTAssertEqual(selected(), "buffer", "最初の一致を選ぶ（祖先の Channel ではない）")

    let editor = try XCTUnwrap(container.field.textField.currentEditor())
    editor.insertText("l")
    XCTAssertEqual(container.field.text, "fl")
    catchUp(hosted.document)
    pumpMain(until: { self.names(outline) == ["Channel", "  flush()"] }, "字を足して絞り込む")
    XCTAssertEqual(selected(), "flush()", "選んでいた行が落ちれば後ろの一致へ")

    let serial = try XCTUnwrap(outline.selection?.serial)
    editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    catchUp(hosted.document)
    pumpMain(until: { outline.rowCount == 6 }, "Esc で絞り込みを解く")
    XCTAssertEqual(selected(), "flush()", "解いても選択は残る")
    XCTAssertGreaterThan(
      try XCTUnwrap(outline.selection?.serial), serial, "選んでいる行を見せ直す（見えていなければ中央へ）")

    list.keyDown(with: .key("f", []))
    catchUp(hosted.document)
    pumpMain(until: { self.names(outline) == ["Channel", "  buffer", "  flush()"] })
    XCTAssertEqual(selected(), "flush()", "選んでいた行が一致なら残す")
    try XCTUnwrap(container.field.textField.currentEditor()).doCommand(
      by: #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(
      hosted.document.surface.selectedRange,
      NSRange(location: offset(hosted, of: "flush"), length: 0), "Enter で一致へ飛ぶ")
  }

  /// 絞り込み中に列から打った字は、入力欄の字の後ろに足す（焦点を得た入力欄の全選択で置き換えない）。
  func testTypingInTheListWhileFilteringAppendsToTheFilter() throws {
    let hosted = try host()
    openOutline(hosted)
    let container = hosted.pane.outlineList
    let list = container.scrollView.list
    hosted.window.makeFirstResponder(list)
    list.keyDown(with: .key("f", []))
    XCTAssertEqual(container.field.text, "f")

    hosted.window.makeFirstResponder(list)
    list.keyDown(with: .key("l", []))
    XCTAssertEqual(container.field.text, "fl")
  }

  /// 絞り込んでいる間は全部を開いた状態から始まる別の畳みを使い、畳んだ親の下の一致も見える。解けば元の畳みに戻る。
  func testFilteringOpensFoldsOnlyWhileFiltering() throws {
    let hosted = try host()
    openOutline(hosted)
    let outline = hosted.pane.outline
    let container = hosted.pane.outlineList
    let list = container.scrollView.list
    outline.setExpanded(try XCTUnwrap(outline.row(at: 0).symbol), false)
    XCTAssertEqual(names(outline), ["Channel", "Box", "  width"], "前提: Channel を畳む")
    hosted.window.makeFirstResponder(list)

    list.keyDown(with: .key("f", []))
    catchUp(hosted.document)
    pumpMain(
      until: { self.names(outline) == ["Channel", "  buffer", "  flush()"] }, "畳んだ親の下の一致も見える")
    try XCTUnwrap(container.field.textField.currentEditor()).doCommand(
      by: #selector(NSResponder.cancelOperation(_:)))
    catchUp(hosted.document)
    pumpMain(until: { self.names(outline) == ["Channel", "Box", "  width"] }, "解けば元の畳みに戻る")
  }

  /// 選んでいたシンボルより後ろに一致が無ければ、頭から最初の一致を選ぶ。
  func testTheMatchAfterTheSelectionWrapsToTheFirst() throws {
    let hosted = try host()
    openOutline(hosted)
    let outline = hosted.pane.outline
    outline.select(row: try row(outline, "width"))

    outline.setFilterText("b")
    catchUp(hosted.document)
    pumpMain(until: { self.names(outline) == ["Channel", "  buffer", "Box"] }, "絞り込む")
    XCTAssertEqual(outline.selectedRow.map { outline.row(at: $0).name }, "buffer")
  }

  /// 別の文書へ移ると絞り込みは解け、戻っても前の文書は絞り込まれていない（VS Code と同じ）。
  func testSwitchingDocumentsClearsTheFilter() throws {
    let hosted = try host()
    openOutline(hosted)
    let outline = hosted.pane.outline
    outline.setFilterText("f")
    catchUp(hosted.document)
    pumpMain(until: { self.names(outline) == ["Channel", "  buffer", "  flush()"] }, "絞り込む")

    let other = try hosted.tab.editor.open(try caseFile("other.swift", "func only() {}\n"))
    catchUp(other)
    pumpMain(until: { self.names(outline) == ["only()"] }, "移った先は絞り込まない")
    XCTAssertEqual(outline.filterText, "")
    XCTAssertFalse(outline.isFilterShown)

    let back = try hosted.tab.editor.open(hosted.document.url)
    XCTAssertTrue(back === hosted.document, "前提: 前の文書へ戻る")
    catchUp(hosted.document)
    pumpMain(until: { outline.rowCount == 6 }, "戻った文書も絞り込まない")
  }
}
