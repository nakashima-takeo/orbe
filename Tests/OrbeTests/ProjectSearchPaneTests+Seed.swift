import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe

/// ⌘⇧F の種と、検索が本文に置いた選択——結果を見て回った後の本文の選択は、検索が置いたままなら種にしない。人が選択を
/// 動かした後は、今までどおり種になる。
///
/// 壊れると何が起きるか。結果を見て回ってからエクスプローラーへ戻り、⌘⇧F で検索パネルを出し直すと、一致の字が検索語を
/// 書き換えて検索し直し、選んでいた行と折りたたみが消える（正規表現の問いは一致の字に置き換わる）。
extension ProjectSearchPaneTests {
  func testTheSelectionThatTheSearchPlacedDoesNotSeed() throws {
    let hosted = try host(["a.txt": "Needle x needle\n", "b.txt": "needle\n"])
    let pane = hosted.pane
    searchAll(hosted, "needle")
    hosted.search.step(forward: true)
    XCTAssertTrue(textHasFocus(hosted), "前提: F4 で本文へ")
    XCTAssertEqual(selectedText(hosted), "Needle", "前提: 検索が一致を本文の選択に置いた")
    hosted.search.toggleCollapse("b.txt")
    let selection = hosted.search.selection

    pane.showExplorer()
    pane.showProjectSearch(seed: pane.projectSearchSeed())
    XCTAssertEqual(hosted.search.query.pattern, "needle", "検索語は書き換わらない")
    XCTAssertEqual(hosted.search.phase, .done, "検索し直さない")
    XCTAssertEqual(hosted.search.selection, selection)
    XCTAssertEqual(hosted.search.collapsed, ["b.txt"])

    hosted.search.setPattern("other")
    let document = try XCTUnwrap(pane.document)
    hosted.window.makeFirstResponder(document.surface.responder)
    XCTAssertNil(pane.projectSearchSeed(), "入力欄で別の語を打った後も、検索が置いた選択は種にしない")

    document.surface.selectedRange = NSRange(location: 3, length: 0)
    document.surface.selectedRange = NSRange(location: 0, length: 6)
    XCTAssertEqual(pane.projectSearchSeed(), "Needle", "キャレットを動かしてから同じ字を選び直すと種になる")
  }
}
