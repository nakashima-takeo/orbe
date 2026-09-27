import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 畳み——見出しの切り替えで、すべて折りたたむ／すべて展開する。絞り込んでいる間の開閉は、その間だけのもの。
extension EditorOutlinePaneTests {
  /// 切り替えはすべて折りたたむ。どれも開いていない間はすべて展開になり、1 つでも開けば次はまたすべて折りたたむ。
  func testTheHeaderToggleCollapsesAllOrExpandsAll() throws {
    let hosted = try host()
    openOutline(hosted)
    let outline = hosted.pane.outline
    XCTAssertFalse(outline.isAllCollapsed, "前提: 開いている")

    outline.toggleCollapseAll()
    XCTAssertEqual(names(outline), ["Channel", "Box"], "すべて折りたたむ")
    XCTAssertTrue(outline.isAllCollapsed, "次はすべて展開")

    outline.setExpanded(try XCTUnwrap(outline.row(at: 0).symbol), true)
    XCTAssertEqual(
      names(outline), ["Channel", "  buffer", "  emit(_:coalesce:)", "  flush()", "Box"])
    XCTAssertFalse(outline.isAllCollapsed, "1 つ開けば次はすべて折りたたむ")
    outline.toggleCollapseAll()
    XCTAssertEqual(names(outline), ["Channel", "Box"])

    outline.toggleCollapseAll()
    XCTAssertEqual(names(outline).count, 6, "すべて展開")
    XCTAssertFalse(outline.isAllCollapsed)
  }

  /// 絞り込んでいる間に畳んだ行は、解いた後の畳みに残らない。
  func testFoldingWhileFilteringDoesNotOutliveTheFilter() throws {
    let hosted = try host()
    openOutline(hosted)
    let outline = hosted.pane.outline
    let container = hosted.pane.outlineList
    let list = container.scrollView.list
    hosted.window.makeFirstResponder(list)

    list.keyDown(with: .key("f", []))
    catchUp(hosted.document)
    pumpMain(until: { self.names(outline) == ["Channel", "  buffer", "  flush()"] }, "絞り込む")
    outline.setExpanded(try XCTUnwrap(outline.row(at: 0).symbol), false)
    XCTAssertEqual(names(outline), ["Channel"], "前提: 絞り込みの中で畳む")

    try XCTUnwrap(container.field.textField.currentEditor()).doCommand(
      by: #selector(NSResponder.cancelOperation(_:)))
    catchUp(hosted.document)
    pumpMain(until: { outline.rowCount == 6 }, "解けば絞り込む前の畳み（すべて開いている）")
  }
}
