import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// ファイル内検索——⌘F で本文の右上にバーが出て入力欄に焦点、needle で全一致に地・キャレット以降の一致を選んで
/// 見せ、Enter / ⇧Enter で循環、本文の編集で一致は追従して選択は動かず、文書の切替は同じ needle で敷き直し、
/// Esc で閉じて焦点がテキスト面へ戻り選択は残る。
///
/// 壊れると何が起きるか。⌘F が端末のスクロールバック検索の意味のまま何も起きない。Enter で同じ一致に留まる。打鍵で
/// 選択が最初の一致へ飛んで打ち込みが乱れる。Esc の後に焦点が窓に落ちて打鍵が消える。
@MainActor
final class EditorSearchTests: OrbeTestCase {
  let style = EditorStyle.make()

  struct Hosted {
    let tab: TerminalTab
    let pane: EditorPaneView
    let document: EditorDocument
    let window: NSWindow
  }

  func host(_ text: String, name: String = "s.txt") throws -> Hosted {
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 700)
    window.appearance = NSAppearance(named: .darkAqua)
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    let document = try tab.editor.open(try caseFile(name, text))
    pane.layoutSubtreeIfNeeded()
    window.makeFirstResponder(document.surface.responder)
    pumpMain(until: { document.surface.viewport.visibleLines > 0 }, "viewport が出る")
    return Hosted(tab: tab, pane: pane, document: document, window: window)
  }

  /// 件数の観測（バーの model は閉じているので、pane が bar へ写す closure に割り込む）。
  func counts(_ pane: EditorPaneView) -> () -> [(Int?, Int)] {
    var seen: [(Int?, Int)] = []
    let forward = pane.search.onCountChange
    pane.search.onCountChange = { selected, total in
      seen.append((selected, total))
      forward?(selected, total)
    }
    return { seen }
  }

  private func row(_ hosted: Hosted, _ offset: Int) -> Int {
    hosted.document.lineIndex.point(at: offset).row
  }

  /// バー（本文の右上に浮く）の下に入らない行から本文を始めるための空行。地を画素で読むテストが使う。
  static let belowTheBar = "\n\n\n\n"

  /// 本文の `line` 行目（1 始まり）・`column` 桁目（0 始まり）のセルの中心（pane の座標）。地の有無は字の無いセルで読む。
  func cellCenter(_ hosted: Hosted, line: Int, column: Int) -> NSPoint {
    let surface = hosted.document.surface.view
    let origin = hosted.pane.convert(surface.bounds, from: surface).origin
    let cell = (" " as NSString).size(withAttributes: [.font: style.font]).width
    return NSPoint(
      x: origin.x + style.gutterWidth + style.marks.gutterWidth + (CGFloat(column) + 0.5) * cell,
      y: origin.y + style.topInset + (CGFloat(line) - 0.5) * style.lineHeight)
  }

  func testCommandFOpensTheBarAtTheTopRightOfTheSurfaceAndFocusesTheField() throws {
    let hosted = try host("foo bar\nfoo baz\nFOO\n")
    let pane = hosted.pane
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("f")))
    let bar = try XCTUnwrap(pane.searchBar)
    pane.layoutSubtreeIfNeeded()
    XCTAssertEqual(bar.frame.maxX, pane.surfaceRect.maxX - 12, accuracy: 0.5, "俯瞰の左・右 12")
    XCTAssertEqual(bar.frame.minY, pane.surfaceRect.minY + 12, accuracy: 0.5, "上 12")
    pumpMain(
      until: { (hosted.window.firstResponder as? NSView)?.isDescendant(of: bar) == true },
      "入力欄に焦点")
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("f")), "表示中の ⌘F は再フォーカスのみ")
    XCTAssertTrue(pane.searchBar === bar, "二重生成しない")
  }

  /// needle で全一致に地が敷かれ、キャレット以降で最初の一致が選ばれる。件数は selected/total。
  func testNeedleHighlightsEveryMatchAndSelectsTheFirstMatchAfterTheCaret() throws {
    let hosted = try host("foo bar\nfoo baz\nFOO\n")
    let pane = hosted.pane
    let seen = counts(pane)
    hosted.document.surface.selectedRange = NSRange(location: 4, length: 0)
    pane.showSearch()
    pane.search.setNeedle("foo")
    XCTAssertEqual(pane.search.matches.map(\.location), [0, 8, 16], "大小無視")
    XCTAssertEqual(
      hosted.document.surface.selectedRange, NSRange(location: 8, length: 3), "キャレット以降で最初")
    pumpMain(until: { seen().last?.0 == 2 }, "件数 2/3")
    XCTAssertEqual(seen().last?.1, 3)
    pane.search.setNeedle("zzz")
    XCTAssertEqual(pane.search.matches, [])
    XCTAssertEqual(seen().last?.1, 0, "一致なし")
    XCTAssertEqual(
      hosted.document.surface.selectedRange, NSRange(location: 8, length: 3), "一致が無ければ選択は残る")
  }

  /// バーの Enter / ⇧Enter は次・前へ循環し、見えていない一致は中央へスクロールして見せる。
  func testNextAndPreviousCycleAndRevealOffscreenMatches() throws {
    var lines = (1...100).map { "line \($0)" }
    for n in [10, 60, 90] { lines[n - 1] += " needle" }
    let hosted = try host(lines.joined(separator: "\n") + "\n")
    let pane = hosted.pane
    let document = hosted.document
    pane.showSearch()
    let bar = try XCTUnwrap(pane.searchBar)
    bar.onNeedleChange?("needle")
    XCTAssertEqual(row(hosted, document.surface.selectedRange.location), 9)
    XCTAssertEqual(document.surface.viewport.firstVisible, 0, "見えている一致ではスクロールしない")

    bar.onNext?()
    XCTAssertEqual(row(hosted, document.surface.selectedRange.location), 59)
    let visible = document.surface.viewport.visibleLines
    pumpMain(until: { document.surface.viewport.firstVisible > 0 }, "見せる")
    XCTAssertEqual(
      CGFloat(row(hosted, document.surface.viewport.firstVisible)), 59 - visible / 2, accuracy: 1.5,
      "見えていない一致は中央へ")

    bar.onNext?()
    XCTAssertEqual(row(hosted, document.surface.selectedRange.location), 89)
    bar.onNext?()
    XCTAssertEqual(row(hosted, document.surface.selectedRange.location), 9, "末尾で先頭へ")
    bar.onPrev?()
    XCTAssertEqual(row(hosted, document.surface.selectedRange.location), 89, "先頭で末尾へ")
    bar.onPrev?()
    XCTAssertEqual(row(hosted, document.surface.selectedRange.location), 59)
  }

  /// 縦に見えていても横に隠れている一致は、横だけ寄せて見せる（縦は動かない）。左端へ戻る一致では横も戻る。
  func testAMatchHiddenToTheRightIsRevealedByScrollingSideways() throws {
    let hosted = try host("x" + String(repeating: " ", count: 200) + "needle\nneedle\n")
    let pane = hosted.pane
    let document = hosted.document
    let scroll = try XCTUnwrap(document.surface.view.subviews.first as? NSScrollView)
    XCTAssertEqual(scroll.contentView.bounds.minX, 0)
    pane.showSearch()
    let bar = try XCTUnwrap(pane.searchBar)
    bar.onNeedleChange?("needle")
    XCTAssertEqual(document.surface.selectedRange.location, 201)
    XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0, "横に寄る")
    XCTAssertEqual(document.surface.viewport.firstVisible, 0, "縦は動かない")

    bar.onNext?()
    XCTAssertEqual(document.surface.selectedRange.location, 208, "2 行目の先頭")
    XCTAssertEqual(scroll.contentView.bounds.minX, 0, "左端の一致で横が戻る")
  }

  /// 本文を編集すると一致と件数は追従し、選択（キャレット）は動かない。
  func testEditingRefreshesMatchesWithoutMovingTheSelection() throws {
    let hosted = try host("ab ab\n")
    let pane = hosted.pane
    let document = hosted.document
    let seen = counts(pane)
    pane.showSearch()
    pane.search.setNeedle("ab")
    XCTAssertEqual(pane.search.matches.count, 2)
    document.surface.selectedRange = NSRange(location: 5, length: 0)
    hosted.window.makeFirstResponder(document.surface.responder)
    for character in " ab" { document.surface.responder.keyDown(with: .key(String(character), [])) }
    XCTAssertEqual(document.surface.text, "ab ab ab\n")
    XCTAssertEqual(pane.search.matches.count, 3, "一致が追従する")
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 8, length: 0), "キャレットは打った先のまま")
    pumpMain(until: { seen().last?.1 == 3 }, "件数が追従する")
  }

  /// ⌘F を押したとき 1 行以内の非空の選択があれば needle に入って即検索される。改行を含む選択は入らない。
  func testSelectionSeedsTheNeedle() throws {
    let hosted = try host("alpha beta\nalpha\n")
    let pane = hosted.pane
    hosted.document.surface.selectedRange = NSRange(location: 6, length: 4)
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("f")))
    XCTAssertEqual(pane.search.needle, "beta")
    XCTAssertEqual(pane.searchBar?.needle, "beta")
    XCTAssertEqual(pane.search.matches.count, 1)
    pane.closeSearch()

    hosted.document.surface.selectedRange = NSRange(location: 6, length: 10)
    pane.showSearch()
    XCTAssertEqual(pane.search.needle, "", "改行をまたぐ選択は種にならない")
  }

  /// Esc で閉じると一致の地は消え、選択は残り、焦点はテキスト面へ戻る。
  func testClosingKeepsTheSelectionAndReturnsFocusToTheText() throws {
    let hosted = try host(Self.belowTheBar + "x a b y\nx a b y\n")
    let pane = hosted.pane
    let document = hosted.document
    pane.showSearch()
    pane.search.setNeedle("a b")
    let bar = try XCTUnwrap(pane.searchBar)
    pumpMain(
      until: { (hosted.window.firstResponder as? NSView)?.isDescendant(of: bar) == true },
      "入力欄に焦点")
    // 地は現在でない一致（選択の地に覆われない）の空白のセルで見る。
    let match = cellCenter(hosted, line: 6, column: 3)
    let ground = try PaneProbe(pane).rgb(match.x, y: cellCenter(hosted, line: 10, column: 3).y)
    _ = try probe(pane) { try !PaneProbe.same($0.rgb(match.x, y: match.y), ground) }

    bar.onClose?()
    XCTAssertNil(pane.searchBar)
    XCTAssertTrue(hosted.window.firstResponder === document.surface.responder, "焦点はテキスト面へ")
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 6, length: 3), "選択は残る")
    XCTAssertEqual(pane.search.matches, [])
    _ = try probe(pane) { try PaneProbe.same($0.rgb(match.x, y: match.y), ground) }
  }

  /// 文書を切り替えると同じ needle で新しい文書に敷き直す（ジャンプしない）。文書が無くなればバーは閉じる。
  func testSwitchingDocumentsReappliesTheNeedleAndClosingTheLastDocumentClosesTheBar() throws {
    let hosted = try host("one two one\n")
    let pane = hosted.pane
    let seen = counts(pane)
    pane.showSearch()
    pane.search.setNeedle("one")
    XCTAssertEqual(pane.search.matches.count, 2)

    let other = try hosted.tab.editor.open(try caseFile("t.txt", "one\n"))
    XCTAssertTrue(pane.search.document === other)
    XCTAssertEqual(pane.search.matches.count, 1, "新しい文書の一致")
    XCTAssertEqual(other.surface.selectedRange, NSRange(location: 0, length: 0), "選択は動かさない")
    pumpMain(until: { seen().last?.1 == 1 }, "件数")
    XCTAssertNotNil(pane.searchBar, "バーは残る")

    hosted.tab.editor.close(other)
    XCTAssertEqual(pane.search.matches.count, 2, "戻れば元の文書の一致")
    hosted.tab.editor.close(hosted.document)
    XCTAssertNil(pane.searchBar, "文書が無くなればバーは閉じる")
  }
}
