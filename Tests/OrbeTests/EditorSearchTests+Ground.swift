import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// ファイル内検索の、バーの外に現れる結果——全一致の地、選択から導く件数、閉じた後の開き直し、文書を汚さないこと。
///
/// 壊れると何が起きるか。一致の地が出ず、選ばれた 1 つ以外どこに一致があるか分からない。本文をクリックしても件数が
/// 前の位置のまま。Esc の後の ⌘F で検索が効かない。検索しただけでファイルタブに未保存の印が付き、⌘Z が検索を戻す。
extension EditorSearchTests {
  /// 全一致に地が敷かれる（現在でない一致も）。一致の無い行は地のまま。needle が変われば敷き直す。
  func testEveryMatchGetsAGroundAndTextWithoutAMatchDoesNot() throws {
    let hosted = try host(Self.belowTheBar + "x a b y\nx a b y\nx c d y\n")
    let pane = hosted.pane
    pane.showSearch()
    pane.search.setNeedle("a b")
    XCTAssertEqual(hosted.document.surface.selectedRange, NSRange(location: 6, length: 3))
    let other = cellCenter(hosted, line: 6, column: 3)
    let unmatched = cellCenter(hosted, line: 7, column: 3)
    let ground = try PaneProbe(pane).rgb(other.x, y: cellCenter(hosted, line: 10, column: 3).y)
    let drawn = try probe(pane) { try !PaneProbe.same($0.rgb(other.x, y: other.y), ground) }
    XCTAssertTrue(
      PaneProbe.same(try drawn.rgb(unmatched.x, y: unmatched.y), ground), "一致の無い行は地のまま")

    pane.search.setNeedle("c d")
    let moved = try probe(pane) { try !PaneProbe.same($0.rgb(unmatched.x, y: unmatched.y), ground) }
    XCTAssertTrue(PaneProbe.same(try moved.rgb(other.x, y: other.y), ground), "前の needle の地は残らない")
  }

  /// 一致の地は本文に付いてスクロールする——見えていなかった一致も、スクロールで現れればその行に地がある。
  func testTheGroundStaysOnItsMatchWhileTheTextScrolls() throws {
    var source = Array(repeating: "", count: 60)
    source[5] = "x a b y"
    source[29] = "x a b y"
    let hosted = try host(source.joined(separator: "\n") + "\n")
    let pane = hosted.pane
    pane.showSearch()
    pane.search.setNeedle("a b")
    XCTAssertEqual(
      hosted.document.lineIndex.point(at: hosted.document.surface.selectedRange.location).row, 5)
    let scrolled = cellCenter(hosted, line: 10, column: 3)
    let ground = try PaneProbe(pane).rgb(scrolled.x, y: cellCenter(hosted, line: 12, column: 3).y)
    XCTAssertTrue(PaneProbe.same(try PaneProbe(pane).rgb(scrolled.x, y: scrolled.y), ground))

    let scroll = try XCTUnwrap(hosted.document.surface.view.subviews.first as? NSScrollView)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: style.lineHeight * 20))
    scroll.reflectScrolledClipView(scroll.contentView)
    _ = try probe(pane) { try !PaneProbe.same($0.rgb(scrolled.x, y: scrolled.y), ground) }
  }

  /// 件数の selected は選択から導く。本文でキャレットを動かせば、その先の一致の番号になる。
  func testTheCountFollowsTheCaretWhenItMovesInTheText() throws {
    let hosted = try host("foo bar\nfoo baz\nFOO\n")
    let pane = hosted.pane
    let seen = counts(pane)
    pane.showSearch()
    pane.search.setNeedle("foo")
    XCTAssertEqual(seen().last?.0, 1)

    hosted.document.surface.selectedRange = NSRange(location: 12, length: 0)
    XCTAssertEqual(seen().last?.0, 3, "キャレットの先の一致")
    XCTAssertEqual(seen().last?.1, 3)
    XCTAssertEqual(pane.search.matches.count, 3, "一致は取り直さない")

    hosted.document.surface.selectedRange = NSRange(location: 19, length: 0)
    XCTAssertEqual(seen().last?.0, 1, "先に一致が無ければ先頭へ循環")
  }

  /// 件数はバーに届く——一致なしはバーの件数が danger（赤）になり、一致が戻れば赤は消える。
  func testNoMatchShowsInTheBarInDangerAndClearsWhenAMatchReturns() throws {
    let hosted = try host("foo bar\n")
    let pane = hosted.pane
    pane.showSearch()
    let bar = try XCTUnwrap(pane.searchBar)
    func type(_ needle: String) {
      bar.needle = needle
      bar.onNeedleChange?(needle)
    }
    /// バーの矩形の中に赤い画素があるか（字の縁の有無でなく、件数の字の色を領域で見る）。
    func barHasRed(_ probe: PaneProbe) throws -> Bool {
      let frame = bar.frame.insetBy(dx: 4, dy: 4)
      return try stride(from: frame.minX, to: frame.maxX, by: 0.5).contains { x in
        try stride(from: frame.minY, to: frame.maxY, by: 0.5).contains { y in
          let c = try probe.rgb(x, y: y)
          return c[0] > c[1] + 50 && c[0] > c[2] + 50
        }
      }
    }

    type("zzz")
    _ = try probe(pane) { try barHasRed($0) }
    type("foo")
    _ = try probe(pane) { try !barHasRed($0) }
  }

  /// Esc で閉じた後の ⌘F は空の needle で開き直り、もう一度同じ文書を検索できる。
  func testReopeningAfterClosingSearchesTheSameDocumentAgain() throws {
    let hosted = try host("one two one\n")
    let pane = hosted.pane
    pane.showSearch()
    pane.search.setNeedle("one")
    try XCTUnwrap(pane.searchBar).onClose?()

    XCTAssertTrue(pane.performKeyEquivalent(with: .key("f")))
    let bar = try XCTUnwrap(pane.searchBar)
    XCTAssertEqual(bar.needle, "one", "選択（閉じる前の一致）が種になる")
    XCTAssertEqual(pane.search.matches.count, 2)
    bar.onNeedleChange?("two")
    XCTAssertEqual(pane.search.matches.map(\.location), [4])
    XCTAssertEqual(hosted.document.surface.selectedRange, NSRange(location: 4, length: 3))
  }

  /// 一致の地と選択は本文にも undo にも載らない——検索しても未保存にならず、⌘Z が戻すものも無い。
  func testSearchingDoesNotDirtyTheDocumentOrEnterTheUndoHistory() throws {
    let text = "foo bar\nfoo baz\n"
    let hosted = try host(text)
    let pane = hosted.pane
    let document = hosted.document
    pane.showSearch()
    pane.search.setNeedle("foo")
    pane.search.next()
    pane.closeSearch()

    XCTAssertEqual(document.surface.text, text)
    XCTAssertFalse(document.isDirty)
    XCTAssertFalse(hosted.tab.editor.hasUnsavedChanges)
    XCTAssertEqual(document.surface.responder.undoManager?.canUndo, false)
  }
}
