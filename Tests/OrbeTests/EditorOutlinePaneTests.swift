import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// エクスプローラーの下段のアウトライン——見えている間の焦点の文書だけが取り出し、行の操作は VS Code どおりに本文へ
/// 飛び（単クリックは焦点を残し、ダブルクリックと Enter は本文へ）、キャレットを動かせば今いるシンボルが選ばれ、列で
/// 打った字から絞り込める。
///
/// 壊れると何が起きるか。アウトラインを閉じていても裏で取り出し続ける・別の文書のアウトラインが出る。行を押すと焦点が
/// 本文へ奪われて ↑↓ で渡り歩けない・違う行へ飛ぶ。キャレットを動かしても光る行が変わらない。打った最初の字が落ちる。
@MainActor
final class EditorOutlinePaneTests: OrbeTestCase {
  private static let source = """
    // header
    class Channel {
      var buffer = 0
      func emit(_ value: Int, coalesce: Bool) {
        buffer += value
      }
      func flush() {
        buffer = 0
      }
    }

    struct Box {
      let width = 1
    }

    """

  private struct Hosted {
    let tab: TerminalTab
    let pane: EditorPaneView
    let window: NSWindow
    let document: EditorDocument
  }

  private func host(_ text: String = source, name: String = "channel.swift") throws -> Hosted {
    let queries = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: queries))
    let window = hostEditor(tab, width: 1000, height: 600)
    let document = try tab.editor.open(try caseFile(name, text))
    let pane = tab.view.editor
    pane.layoutSubtreeIfNeeded()
    let outline = pane.outline
    outline.clickDelay.schedule = { _, fire in fire() }
    outline.followDelay.schedule = { _, fire in fire() }
    outline.loadingDelay.schedule = { _, fire in fire() }
    return Hosted(tab: tab, pane: pane, window: window, document: document)
  }

  private func openOutline(_ hosted: Hosted) {
    hosted.pane.sidebar.toggleOutline()
    pumpMain(until: { hosted.document.wantsOutline }, "アウトラインが要ると告げる")
    catchUp(hosted.document)
    pumpMain(until: { hosted.pane.outline.status == .ready }, "結果が届く")
    pumpMain(until: { hosted.pane.outlineList.window != nil }, "列が出る")
    hosted.pane.layoutSubtreeIfNeeded()
  }

  private func names(_ outline: EditorOutline) -> [String] {
    (0..<outline.rowCount).map {
      let row = outline.row(at: $0)
      return String(repeating: "  ", count: row.depth) + row.name
    }
  }

  private func row(_ outline: EditorOutline, _ name: String) throws -> Int {
    try XCTUnwrap((0..<outline.rowCount).first { outline.row(at: $0).name == name })
  }

  private func offset(_ hosted: Hosted, of needle: String) -> Int {
    (hosted.document.text.substring(NSRange(location: 0, length: hosted.document.text.length))
      as NSString).range(of: needle).location
  }

  private func key(_ special: NSEvent.SpecialKey) -> NSEvent {
    .key(String(UnicodeScalar(special.rawValue)!), [])
  }

  private func click(_ list: NSView, row: Int, x: CGFloat, count: Int) {
    let point = NSPoint(x: x, y: (CGFloat(row) + 0.5) * Theme.Layout.editorRow)
    let event = NSEvent.mouseEvent(
      with: .leftMouseDown, location: list.convert(point, to: nil), modifierFlags: [],
      timestamp: 0, windowNumber: list.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
      clickCount: count, pressure: 1)!
    list.mouseDown(with: event)
  }

  // MARK: - いつ取り出すか

  /// 取り出すのは、アウトラインが見えている間の焦点の文書だけ——閉じる・検索パネルへ切り替える・別の文書へ移ると
  /// 要らないと告げる。
  func testOnlyTheFocusedDocumentWantsTheOutlineWhileItIsShown() throws {
    let hosted = try host()
    XCTAssertFalse(hosted.document.wantsOutline, "既定は閉")
    openOutline(hosted)
    XCTAssertEqual(
      names(hosted.pane.outline),
      ["Channel", "  buffer", "  emit(_:coalesce:)", "  flush()", "Box", "  width"])

    hosted.pane.sidebar.select(.search)
    pumpMain(until: { !hosted.document.wantsOutline }, "検索パネルでは要らない")
    hosted.pane.sidebar.select(.files)
    pumpMain(until: { hosted.document.wantsOutline }, "エクスプローラーへ戻れば要る")

    let other = try hosted.tab.editor.open(try caseFile("other.swift", "func only() {}\n"))
    XCTAssertFalse(hosted.document.wantsOutline, "焦点を外れた文書は要らない")
    XCTAssertTrue(other.wantsOutline)
    catchUp(other)
    pumpMain(until: { self.names(hosted.pane.outline) == ["only()"] }, "焦点の文書のアウトライン")

    hosted.pane.sidebar.toggleOutline()
    pumpMain(until: { !other.wantsOutline }, "閉じれば要らない")
  }

  /// テキストのように文法の無い文書は、出せないという文言になる。
  func testAFileWithoutAGrammarIsUnavailable() throws {
    let hosted = try host("plain\n", name: "notes.txt")
    hosted.pane.sidebar.toggleOutline()
    pumpMain(until: { hosted.pane.outline.status == .unavailable })
  }

  // MARK: - 操作

  /// 単クリックは名前の頭へキャレットを置いて焦点を列に残し、ダブルクリックは範囲全体を選んで本文へ、Enter は名前の頭へ
  /// 置いて本文へ。行を押しても開閉せず、シェブロンで開閉する。
  func testClicksAndEnterJumpToTheSymbolLikeVSCode() throws {
    let hosted = try host()
    openOutline(hosted)
    let outline = hosted.pane.outline
    let list = hosted.pane.outlineList.scrollView.list
    let emit = try row(outline, "emit(_:coalesce:)")

    click(list, row: emit, x: 120, count: 1)
    XCTAssertEqual(
      hosted.document.surface.selectedRange,
      NSRange(location: offset(hosted, of: "emit"), length: 0))
    XCTAssertTrue(hosted.window.firstResponder === list, "単クリックは焦点を列に残す")

    click(list, row: emit, x: 120, count: 2)
    let range = hosted.document.surface.selectedRange
    XCTAssertEqual(range.location, offset(hosted, of: "func emit"))
    XCTAssertTrue(
      hosted.document.text.substring(range).hasSuffix("}"), "ダブルクリックは範囲全体を選ぶ")
    XCTAssertTrue(hosted.window.firstResponder === hosted.document.surface.responder)

    hosted.window.makeFirstResponder(list)
    let flush = try row(outline, "flush()")
    outline.select(row: flush)
    list.keyDown(with: .key("\r", []))
    XCTAssertEqual(
      hosted.document.surface.selectedRange,
      NSRange(location: offset(hosted, of: "flush"), length: 0))
    XCTAssertTrue(hosted.window.firstResponder === hosted.document.surface.responder, "Enter は本文へ")

    hosted.window.makeFirstResponder(list)
    let channel = try row(outline, "Channel")
    click(list, row: channel, x: 60, count: 1)
    XCTAssertEqual(outline.rowCount, 6, "行を押しても開閉しない")
    click(list, row: channel, x: Theme.Layout.editorOutlineInset + 4, count: 1)
    XCTAssertEqual(names(outline), ["Channel", "Box", "  width"], "シェブロンで畳む")
  }

  /// ↑↓ は選ぶだけ、← は畳んで親へ、→ は開いて子へ、Space は開閉。
  func testKeysMoveTheSelectionAndFold() throws {
    let hosted = try host()
    openOutline(hosted)
    let outline = hosted.pane.outline
    let list = hosted.pane.outlineList.scrollView.list
    hosted.window.makeFirstResponder(list)
    let caret = hosted.document.surface.selectedRange

    list.keyDown(with: key(.downArrow))
    list.keyDown(with: key(.downArrow))
    XCTAssertEqual(outline.selectedRow, 1)
    XCTAssertEqual(hosted.document.surface.selectedRange, caret, "↑↓ は飛ばない")
    list.keyDown(with: key(.leftArrow))
    XCTAssertEqual(outline.selectedRow, 0, "子の ← は親へ")
    list.keyDown(with: key(.leftArrow))
    XCTAssertEqual(outline.rowCount, 3, "開いた親の ← は畳む")
    list.keyDown(with: key(.rightArrow))
    XCTAssertEqual(outline.rowCount, 6, "畳んだ親の → は開く")
    list.keyDown(with: key(.rightArrow))
    XCTAssertEqual(outline.selectedRow, 1, "開いた親の → は最初の子へ")
    list.keyDown(with: key(.upArrow))
    list.keyDown(with: .key(" ", []))
    XCTAssertEqual(outline.rowCount, 3, "Space は開閉")
  }

  /// キャレットが止むと、含む最も深いシンボルが選ばれ、畳んだ祖先は開く。どれにも入らなければ選択を外す。
  func testTheCaretIsFollowed() throws {
    let hosted = try host()
    openOutline(hosted)
    let outline = hosted.pane.outline
    let list = hosted.pane.outlineList.scrollView.list
    hosted.window.makeFirstResponder(list)
    list.keyDown(with: key(.downArrow))
    list.keyDown(with: key(.leftArrow))
    XCTAssertEqual(outline.rowCount, 3, "前提: Channel を畳む")

    hosted.document.surface.selectedRange = NSRange(
      location: offset(hosted, of: "    buffer = 0"), length: 0)
    pumpMain(until: { outline.selectedRow.map { outline.row(at: $0).name } == "flush()" }, "追従")
    XCTAssertEqual(outline.rowCount, 6, "畳んだ祖先を開く")
    XCTAssertTrue(hosted.window.firstResponder === list, "焦点は奪わない")

    hosted.document.surface.selectedRange = NSRange(location: 2, length: 0)
    pumpMain(until: { outline.selection == nil }, "どのシンボルにも入らなければ外す")
  }

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

    editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    catchUp(hosted.document)
    pumpMain(until: { outline.rowCount == 6 }, "Esc で絞り込みを解く")
    XCTAssertEqual(selected(), "flush()", "解いても選択は残る")

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

  /// 取り直しても、同じ名前の道筋にあるシンボルの畳みは残る。
  func testFoldsSurviveARefresh() throws {
    let hosted = try host()
    openOutline(hosted)
    let outline = hosted.pane.outline
    outline.setExpanded(try XCTUnwrap(outline.row(at: 0).symbol), false)
    XCTAssertEqual(outline.rowCount, 3)
    hosted.document.surface.replaceAll(with: "func top() {}\n" + Self.source)
    catchUp(hosted.document)
    pumpMain(until: { outline.row(at: 0).name == "top()" }, "取り直す")
    XCTAssertEqual(names(outline), ["top()", "Channel", "Box", "  width"])
  }
}
