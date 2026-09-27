import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// エクスプローラーの 2 段の境——境を端まで引いても、アウトラインの列には最小の行数が欠けずに残る。
extension EditorOutlinePaneTests {
  /// 境を下端まで引いたとき、アウトラインの列の高さは区画の最小の中身（行 3 本）のまま（見出しの下の間に食われない）。
  func testTheOutlineKeepsItsMinimumRowsWholeWhenTheSplitIsDraggedDown() throws {
    let hosted = try host()
    openOutline(hosted)
    let list = hosted.pane.outlineList

    hosted.pane.sidebar.setOutlineFraction(0)
    hosted.pane.layoutSubtreeIfNeeded()
    XCTAssertEqual(list.convert(list.bounds, to: nil).height, Theme.Layout.editorSectionMinBody)
  }
}
