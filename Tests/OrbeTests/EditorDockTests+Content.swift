import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 開いている間のポップアップの中身——本体が置き換わっても、置き場が組み直されても、中身とフォーカスはそのまま残り、閉じて
/// 開き直せば中身は新しくなる。
///
/// 壊れると何が起きるか（`EditorDockTests` の説明に書いたことのほか）。書きかけの途中で中身が作り直され、打った字と変換中の
/// 字が消える。閉じてすぐ開き直すと、前に開いた中身の状態が残る。
extension EditorDockTests {
  /// 開いたまま本体が別の文書に置き換わっても、中身の欄のフォーカスは本体へ移らず、ポップアップは開いたまま。
  func testReplacingTheBodyKeepsTheFocusInThePopup() throws {
    let hosted = try host()
    let owner = Owner()
    hosted.popup.toggle(owner)
    XCTAssertTrue(hosted.window.firstResponder === owner.field, "前提: 中身の欄にフォーカス")

    let next = try hosted.tab.group.editor.open(try caseFile("b.txt", "b"), as: .pinned)
    pumpMain(until: { hosted.pane.document === next }, "前提: 本体が置き換わる")
    nextTurn()
    XCTAssertTrue(hosted.window.firstResponder === owner.field, "フォーカスは中身の欄に残る")
    XCTAssertTrue(hosted.popup.isOpen)
  }

  /// 開いている間に置き場が組み直されても、中身は作り直されず、フォーカスも残る。閉じてすぐ（置き場が描き直される前に）
  /// 開き直しても、中身は新しくなる。
  func testThePopupContentLastsWhileOpenAndIsNewOnEachOpen() throws {
    let hosted = try host()
    let pane = hosted.pane
    let owner = Owner()
    hosted.popup.toggle(owner)
    pumpMain(until: { owner.contentStamps.count == 1 }, "前提: 中身が窓に載る")

    let calls = owner.contentCalls
    for panel in [EditorShellModel.Panel.search, .files] {
      pane.filesPanel = panel
      flush(hosted.window)
    }
    XCTAssertGreaterThan(owner.contentCalls, calls, "前提: 置き場が組み直された")
    XCTAssertEqual(owner.contentStamps.count, 1, "中身は作り直されない")
    XCTAssertTrue(hosted.window.firstResponder === owner.field, "フォーカスは中身の欄に残る")
    XCTAssertTrue(hosted.popup.isOpen)

    // フォーカスを動かさないきっかけで閉じ、置き場が描き直される前に開き直す。
    hosted.popup.close(.focusLeft)
    hosted.popup.open(owner)
    pumpMain(until: { owner.contentStamps.count == 2 }, "開き直した中身が窓に載る")
    XCTAssertNotEqual(owner.contentStamps[0], owner.contentStamps[1], "開き直した中身は新しい")
  }
}
