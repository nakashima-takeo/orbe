import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 結果の列（NSTableView）——キーとマウスは model の操作に届き（表は自分で選択を動かさない）、表の選択は model の選択を写し、
/// 結果が変わると見えている行は作り直さずに中身と高さが揃い、VoiceOver には行の中身の文字列が渡る。
///
/// 壊れると何が起きるか。列に焦点があっても ↑↓ が効かない、表の既定の動きで model と違う行が選ばれて見える。新しい結果が
/// 届いても前の結果の行が残る、見出しと一致の高さがずれて行が重なる。VoiceOver が行を読めない。
extension ProjectSearchPaneTests {
  func table(_ hosted: Hosted) throws -> SearchResultsTableView {
    pumpMain(until: { self.findTable(in: hosted.pane.sideHost) != nil }, "結果の列が出る")
    return try XCTUnwrap(findTable(in: hosted.pane.sideHost))
  }

  private func findTable(in view: NSView) -> SearchResultsTableView? {
    if let table = view as? SearchResultsTableView { return table }
    for subview in view.subviews {
      if let table = findTable(in: subview) { return table }
    }
    return nil
  }

  private func rowView(_ table: NSTableView, _ row: Int) throws -> SearchResultRowView {
    try XCTUnwrap(table.rowView(atRow: row, makeIfNecessary: false) as? SearchResultRowView)
  }

  private func key(_ special: NSEvent.SpecialKey) -> NSEvent {
    .key(String(UnicodeScalar(special.rawValue)!), [])
  }

  private func click(_ table: NSTableView, row: Int, count: Int) {
    let rect = table.rect(ofRow: row)
    let event = NSEvent.mouseEvent(
      with: .leftMouseDown, location: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
      modifierFlags: [], timestamp: 0, windowNumber: table.window?.windowNumber ?? 0, context: nil,
      eventNumber: 0, clickCount: count, pressure: 1)!
    table.mouseDown(with: event)
  }

  func testTheTablesKeysReachTheModelAndItsSelectionMirrorsTheModel() throws {
    let hosted = try host(["a.txt": "needle\nneedle\n", "b.txt": "needle\n"])
    _ = try open(hosted, "b.txt")
    searchAll(hosted, "needle")
    let table = try table(hosted)
    hosted.search.focusResults()
    pumpMain(until: { hosted.window.firstResponder === table }, "⌘↓ の要求で列に焦点")
    XCTAssertEqual(hosted.search.focusedArea, .results)

    table.keyDown(with: key(.downArrow))
    XCTAssertEqual(hosted.search.selection, RowID(path: "a.txt", match: 0), "↓ は選択だけを動かす")
    pumpMain(until: { table.selectedRow == 1 }, "表の選択は model の選択を写す")
    table.keyDown(with: key(.leftArrow))
    XCTAssertEqual(hosted.search.selection, RowID(path: "a.txt", match: nil), "← は親の見出しへ")
    table.keyDown(with: key(.leftArrow))
    XCTAssertTrue(hosted.search.collapsed.contains("a.txt"), "見出しの ← は畳む")
    pumpMain(until: { table.numberOfRows == 3 }, "畳んだ行は列から消える")

    table.keyDown(with: .key("\u{1b}", []))
    XCTAssertNil(hosted.search.selection, "Esc は選択を外す")
    pumpMain(until: { table.selectedRow == -1 })

    table.keyDown(with: key(.downArrow))
    table.keyDown(with: key(.downArrow))
    table.keyDown(with: .key("\r", []))
    XCTAssertEqual(hosted.search.selection, RowID(path: "b.txt", match: 0), "見出しの Enter は最後の一致")
    XCTAssertTrue(textHasFocus(hosted), "Enter は開いて本文へ")
  }

  func testClickingARowSelectsAndOpensAndADoubleClickMovesTheFocusToTheText() throws {
    let hosted = try host(["a.txt": "needle\nneedle\n"])
    searchAll(hosted, "needle")
    let table = try table(hosted)
    pumpMain(until: { table.numberOfRows == 3 })

    click(table, row: 2, count: 1)
    XCTAssertEqual(hosted.search.selection, RowID(path: "a.txt", match: 1))
    XCTAssertEqual(hosted.pane.document?.url, hosted.repo.url("a.txt"), "一致を押すと開く")
    XCTAssertTrue(hosted.window.firstResponder === table, "シングルクリックは焦点を列に置く")

    click(table, row: 1, count: 2)
    XCTAssertEqual(hosted.search.selection, RowID(path: "a.txt", match: 0))
    XCTAssertTrue(textHasFocus(hosted), "ダブルクリックは本文へ")

    click(table, row: 0, count: 1)
    XCTAssertTrue(hosted.search.collapsed.contains("a.txt"), "見出しを押すと開閉")
  }

  /// 新しい結果が届くと、見えている行は中身と高さが新しい行に揃う（見出し 22・一致 20）。VoiceOver には行の中身を渡す。
  func testNewResultsReplaceTheVisibleRowsInPlace() throws {
    let hosted = try host(["a.txt": "alpha needle\n", "b.txt": "beta needle\nbeta needle\n"])
    searchAll(hosted, "needle")
    let table = try table(hosted)
    pumpMain(until: { table.numberOfRows == 5 })
    XCTAssertEqual(try rowView(table, 0).accessibilityLabel(), "a.txt, 1")
    XCTAssertEqual(try rowView(table, 1).accessibilityLabel(), "alpha needle")
    XCTAssertEqual(table.rect(ofRow: 0).height, Theme.Layout.editorSearchFileRow)
    XCTAssertEqual(table.rect(ofRow: 1).height, Theme.Layout.editorSearchMatchRow)

    hosted.search.setPattern("beta")
    hosted.search.search()
    pumpMain(until: { hosted.search.phase == .done })
    pumpMain(until: { table.numberOfRows == 3 }, "行の数が新しい結果に揃う")
    XCTAssertEqual(try rowView(table, 0).accessibilityLabel(), "b.txt, 2")
    XCTAssertEqual(try rowView(table, 1).accessibilityLabel(), "beta needle")
    XCTAssertEqual(table.rect(ofRow: 1).minY, Theme.Layout.editorSearchFileRow)
    XCTAssertEqual(
      table.rect(ofRow: 2).minY,
      Theme.Layout.editorSearchFileRow + Theme.Layout.editorSearchMatchRow)
  }
}
