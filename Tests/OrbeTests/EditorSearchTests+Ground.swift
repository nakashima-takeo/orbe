import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// ファイル内検索の、バーの外に現れる結果——全一致の地と現在の一致の地（編集の間も字に付く）、選択から導く件数、閉じた後の
/// 開き直し、文書を汚さないこと。
///
/// 壊れると何が起きるか。一致の地が出ず、選ばれた 1 つ以外どこに一致があるか分からない。現在の一致が他の一致と見分け
/// られない、本文をクリックしても現在の地が残る。打鍵の間、地が字から外れる。本文をクリックしても件数が
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

  /// 現在の一致（選択がちょうど一致）は他の一致と違う地で見分けられ、その行全体にも地が付く。選択が一致から外れると
  /// （本文のクリック）、その一致は他の一致と同じ地に戻り、行の地も消える。
  func testTheCurrentMatchStandsOutUntilTheSelectionLeavesIt() throws {
    let hosted = try host(Self.belowTheBar + "x a b y\nx a b y\n")
    let pane = hosted.pane
    pane.showSearch()
    pane.search.setNeedle("a b")
    XCTAssertEqual(
      hosted.document.surface.selectedRange, NSRange(location: 6, length: 3), "前提: 5 行目の一致が現在")
    // 現在の一致（5 行目）と他の一致（6 行目）の組——一致の中の空白のセルと、行の右の空きのセル。
    let pairs = [
      (cellCenter(hosted, line: 5, column: 3), cellCenter(hosted, line: 6, column: 3)),
      (cellCenter(hosted, line: 5, column: 12), cellCenter(hosted, line: 6, column: 12)),
    ]
    func alike(_ probe: PaneProbe) throws -> [Bool] {
      try pairs.map {
        try PaneProbe.same(probe.rgb($0.0.x, y: $0.0.y), probe.rgb($0.1.x, y: $0.1.y))
      }
    }
    let lit = try alike(probe(pane) { try alike($0) == [false, false] })
    XCTAssertEqual(lit, [false, false], "現在の一致は他の一致と違う地で、その行には行全体の地")

    hosted.document.surface.selectedRange = NSRange(location: 0, length: 0)
    XCTAssertNil(pane.search.current)
    let left = try alike(probe(pane) { try alike($0) == [true, true] })
    XCTAssertEqual(left, [true, true], "外れた一致は他の一致と同じ地に戻り、行の地も消える")
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

  /// 本文を編集してから一致を取り直すまでの間も、一致の地は編集に合わせてずれ、字から離れない。
  func testTheGroundFollowsAnEditBeforeTheMatchesAreRefreshed() throws {
    let hosted = try host(Self.belowTheBar + "a b y\n")
    let pane = hosted.pane
    let document = hosted.document
    pane.showSearch()
    pane.search.setNeedle("a b")
    pane.search.refreshDelay.schedule = { _, _ in }
    document.surface.selectedRange = NSRange(location: 4, length: 0)
    hosted.window.makeFirstResponder(document.surface.responder)
    for character in "zz" { document.surface.responder.keyDown(with: .key(String(character), [])) }
    XCTAssertEqual(document.surface.text, Self.belowTheBar + "zza b y\n")
    let moved = cellCenter(hosted, line: 5, column: 3)
    let ground = try PaneProbe(pane).rgb(moved.x, y: cellCenter(hosted, line: 10, column: 3).y)
    _ = try probe(pane) { try !PaneProbe.same($0.rgb(moved.x, y: moved.y), ground) }
  }

  /// 件数の位置は選択から導く——選択がちょうど一致ならその番号、一致でなければ位置は無い（バーは「?/N」）。本文を
  /// クリックして一致から外れても同じ。Enter はキャレットの先の一致へ進む。
  func testTheCountPositionFollowsTheSelection() throws {
    let hosted = try host("foo bar\nfoo baz\nFOO\n")
    let pane = hosted.pane
    let seen = counts(pane)
    pane.showSearch()
    XCTAssertEqual(pane.search.needle, "foo", "前提: キャレットの語が種")
    XCTAssertNil(seen().last?.0, "キャレットは一致ではない")
    pane.search.next()
    XCTAssertEqual(seen().last?.0, 1)

    hosted.document.surface.selectedRange = NSRange(location: 12, length: 0)
    XCTAssertNil(seen().last?.0, "選択が一致から外れれば位置は無い")
    XCTAssertEqual(seen().last?.1, 3)
    XCTAssertNil(pane.search.current, "現在の一致も無い")
    XCTAssertEqual(pane.search.matches.count, 3, "一致は取り直さない")

    pane.search.next()
    XCTAssertEqual(seen().last?.0, 3, "Enter はキャレットの先の一致へ")
    XCTAssertEqual(hosted.document.surface.selectedRange, NSRange(location: 16, length: 3))
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
