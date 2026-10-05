import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 結果の列（行の列の部品 `RowList` に検索結果の源をつないだもの）——キーとマウスは model の操作に届き（列は自分で選択を
/// 動かさない）、列の選択は model の選択を写す。行の view は結果が変わっても・パネルを隠して出し直しても作り直さず、中身と
/// VoiceOver の読み（見出しはファイル名・件数、一致は行のプレビュー）だけが揃う。送りキー・選択を見せる送り・VoiceOver の
/// リストの形は部品そのもの（`RowListTests`）が固める。
///
/// 壊れると何が起きるか。列に焦点があっても ↑↓ が効かない。新しい結果が届いても前の結果の行が残る、パネルを出し直す
/// たびに列が作り直されて重い。VoiceOver が行の中身を読めない。
extension ProjectSearchPaneTests {
  func list(_ hosted: Hosted) throws -> RowListView<SearchResultsSource> {
    pumpMain(until: { hosted.pane.searchResults.window != nil }, "結果の列が出る")
    return hosted.pane.searchResults.list
  }

  /// 行 `row` を描いている行の view（見えていなければ nil）。
  private func rowView(_ list: RowListView<SearchResultsSource>, _ row: Int) -> SearchResultRowView?
  {
    list.subviews.lazy.compactMap { $0 as? SearchResultRowView }
      .first { $0.row == row && !$0.isHidden }
  }

  private func key(_ special: NSEvent.SpecialKey) -> NSEvent {
    .key(String(UnicodeScalar(special.rawValue)!), [])
  }

  private func click(_ list: RowListView<SearchResultsSource>, row: Int, count: Int) {
    let point = NSPoint(x: 20, y: (CGFloat(row) + 0.5) * Theme.Layout.editorSearchRow)
    let event = NSEvent.mouseEvent(
      with: .leftMouseDown, location: list.convert(point, to: nil), modifierFlags: [],
      timestamp: 0, windowNumber: list.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
      clickCount: count, pressure: 1)!
    list.mouseDown(with: event)
  }

  func testTheListsKeysReachTheModelAndItsSelectionMirrorsTheModel() throws {
    let hosted = try host(["a.txt": "needle\nneedle\n", "b.txt": "needle\n"])
    _ = try open(hosted, "b.txt")
    searchAll(hosted, "needle")
    let list = try list(hosted)
    hosted.search.focusResults()
    pumpMain(until: { hosted.window.firstResponder === list }, "⌘↓ の要求で列に焦点")
    XCTAssertEqual(hosted.search.focusedArea, .results)

    list.keyDown(with: key(.downArrow))
    XCTAssertEqual(hosted.search.selection, RowID(path: "a.txt", match: 0))
    XCTAssertEqual(hosted.pane.document?.url, hosted.repo.url("a.txt"), "↓ で動いた一致を開く")
    XCTAssertTrue(hosted.window.firstResponder === list, "焦点は列に残る")
    pumpMain(
      until: { list.selectedRow == 1 && self.rowView(list, 1)?.isSelected == true },
      "列の選択は model の選択を写す")
    list.keyDown(with: key(.leftArrow))
    XCTAssertEqual(hosted.search.selection, RowID(path: "a.txt", match: nil), "← は親の見出しへ")
    list.keyDown(with: key(.leftArrow))
    XCTAssertTrue(hosted.search.collapsed.contains("a.txt"), "見出しの ← は畳む")
    pumpMain(until: { list.rowCount == 3 }, "畳んだ行は列から消える")

    list.keyDown(with: .key("\u{1b}", []))
    XCTAssertNil(hosted.search.selection, "Esc は選択を外す")
    pumpMain(until: { list.selectedRow == nil })

    list.keyDown(with: key(.downArrow))
    list.keyDown(with: key(.downArrow))
    list.keyDown(with: .key("\r", []))
    XCTAssertEqual(hosted.search.selection, RowID(path: "b.txt", match: 0), "見出しの Enter は最後の一致")
    XCTAssertTrue(textHasFocus(hosted), "Enter は開いて本文へ")
  }

  func testClickingARowSelectsAndOpensAndADoubleClickMovesTheFocusToTheText() throws {
    let hosted = try host(["a.txt": "needle\nneedle\n"])
    searchAll(hosted, "needle")
    let list = try list(hosted)
    pumpMain(until: { list.rowCount == 3 })

    click(list, row: 2, count: 1)
    XCTAssertEqual(hosted.search.selection, RowID(path: "a.txt", match: 1))
    XCTAssertEqual(hosted.pane.document?.url, hosted.repo.url("a.txt"), "一致を押すと開く")
    XCTAssertTrue(hosted.window.firstResponder === list, "シングルクリックは焦点を列に置く")

    click(list, row: 1, count: 2)
    XCTAssertEqual(hosted.search.selection, RowID(path: "a.txt", match: 0))
    XCTAssertTrue(textHasFocus(hosted), "ダブルクリックは本文へ")

    click(list, row: 0, count: 1)
    XCTAssertTrue(hosted.search.collapsed.contains("a.txt"), "見出しを押すと開閉")
  }

  /// 新しい結果が届いても、パネルを隠して出し直しても、列と行の view は作り直さず中身だけが揃う。行の高さは 1 つ。
  func testTheListKeepsItsRowViewsAcrossResultsAndPanelSwitches() throws {
    let hosted = try host(["a.txt": "alpha needle\n", "b.txt": "beta needle\nbeta needle\n"])
    searchAll(hosted, "needle")
    let list = try list(hosted)
    pumpMain(until: { list.rowCount == 5 })
    let first = try XCTUnwrap(rowView(list, 0))
    XCTAssertEqual(first.accessibilityLabel(), "a.txt, 1")
    XCTAssertEqual(rowView(list, 1)?.accessibilityLabel(), "alpha needle")
    XCTAssertEqual(list.frame.height, Theme.Layout.editorSearchRow * 5, "行の高さは 1 つ")

    hosted.search.setPattern("beta")
    hosted.search.search()
    pumpMain(until: { hosted.search.phase == .done })
    pumpMain(until: { list.rowCount == 3 }, "行の数が新しい結果に揃う")
    XCTAssertTrue(rowView(list, 0) === first, "行の view は使い回す")
    XCTAssertEqual(first.accessibilityLabel(), "b.txt, 2")
    XCTAssertEqual(rowView(list, 1)?.accessibilityLabel(), "beta needle")
    XCTAssertEqual(rowView(list, 3), nil, "無い行の view は隠れる")

    hosted.pane.sidebar.select(.files)
    pumpMain(until: { hosted.pane.searchResults.window == nil }, "パネルを隠すと列は外れる")
    hosted.pane.showProjectSearch(seed: nil)
    pumpMain(until: { hosted.pane.searchResults.window != nil }, "出し直すと同じ列が載る")
    XCTAssertTrue(hosted.pane.searchResults.list === list)
    XCTAssertTrue(rowView(list, 0) === first, "出し直しても行の view を作り直さない")
  }

  /// 送ったとき描き直すのは新しく見えた行だけ（端で見え方の変わる行を含めて 2 行まで）。見えたままの行は描き直さない。
  func testScrollingRedrawsOnlyTheNewlyVisibleRows() throws {
    let text = (0..<200).map { "needle \($0)" }.joined(separator: "\n") + "\n"
    let hosted = try host(["a.txt": text])
    searchAll(hosted, "needle")
    let list = try list(hosted)
    pumpMain(until: { list.rowCount == 201 })
    let scroll = hosted.pane.searchResults
    let draws = RowDrawCounter()
    func display() {
      hosted.window.displayIfNeeded()
      CATransaction.flush()
    }
    func redrawn(scrollingBy step: CGFloat) -> Int {
      display()
      let before = draws.count
      let clip = scroll.contentView
      clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + step))
      scroll.reflectScrolledClipView(clip)
      display()
      return draws.count - before
    }
    for _ in 0..<3 {
      XCTAssertLessThanOrEqual(redrawn(scrollingBy: Theme.Layout.editorSearchRow), 2, "1 行ぶん送る")
      XCTAssertLessThanOrEqual(redrawn(scrollingBy: 7), 2, "7pt 送る（端で見え方の変わる行まで）")
    }
  }
}

/// 行の view が描いた回数を数える（テストの間だけ `draw(_:)` を包む）。
@MainActor
final class RowDrawCounter {
  private(set) var count = 0
  nonisolated(unsafe) private static var current: RowDrawCounter?
  private static var installed = false

  init() {
    Self.current = self
    guard !Self.installed else { return }
    Self.installed = true
    let selector = #selector(NSView.draw(_:))
    guard let method = class_getInstanceMethod(SearchResultRowView.self, selector) else { return }
    typealias Draw = @convention(c) (AnyObject, Selector, NSRect) -> Void
    let original = unsafeBitCast(method_getImplementation(method), to: Draw.self)
    let counted: @convention(block) (AnyObject, NSRect) -> Void = { view, rect in
      MainActor.assumeIsolated { RowDrawCounter.current?.count += 1 }
      original(view, selector, rect)
    }
    method_setImplementation(method, imp_implementationWithBlock(counted))
  }
}
