import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorText

/// 行番号の列——本文の左に並び、行索引の行の番号を描き、桁が増えれば広がる。番号を押すとその行を選び（VS Code の既定）、
/// 印の列は押しても何もしない。
///
/// 壊れると何が起きるか。単独の `\r` で割れた段落に余計な番号が付き、番号が行索引（ミニマップ・スクロールバー・検索の
/// 行）とずれる。10 万行の文書で番号の頭が欠ける。スクロールしても番号が見えている行に替わらない。行番号を押しても行を
/// 選べない、ドラッグや ⇧クリックの伸び方が VS Code と違う、印の列を押したつもりで行が選ばれる。列の上でホイールを回しても
/// 本文が動かない。
@MainActor
final class EditorLineNumbersTests: OrbeTestCase {
  let style = EditorStyle.make()

  struct Opened {
    let document: EditorDocument
    let window: NSWindow
    let column: LineNumbersView
    let scroll: NSScrollView
  }

  /// `text` を開いた 400×200 の面。
  func open(_ text: String) throws -> Opened {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let url = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent(
      "n-\(UUID().uuidString).txt")
    try Data(text.utf8).write(to: url)
    let document = try session.open(url)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = document.surface.view
    document.surface.view.frame = try XCTUnwrap(window.contentView).bounds
    document.surface.view.layoutSubtreeIfNeeded()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    pumpMain(until: { document.surface.viewport.visibleLines > 0 }, "viewport が出る")
    withExtendedLifetime(session) {}
    return Opened(
      document: document, window: window,
      column: try XCTUnwrap(document.surface.view.subviews.last as? LineNumbersView),
      scroll: try XCTUnwrap(document.surface.view.subviews.first as? NSScrollView))
  }

  func lines(_ n: Int) -> String { (1...n).map { "line \($0)\n" }.joined() }

  /// 列の画素を読み、行ごと（1 始まり）に字が描かれているかを返す。
  private func inkedRows(_ opened: Opened, count: Int) throws -> [Bool] {
    let view = opened.document.surface.view
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    return try (1...count).map { row in
      let top = style.topInset + CGFloat(row - 1) * style.lineHeight
      return try stride(from: top + 2, to: top + style.lineHeight - 2, by: 1).contains { y in
        try stride(from: 2, to: style.gutterWidth, by: 1).contains { x in
          let color = try XCTUnwrap(
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
          return color.alphaComponent > 0.3
        }
      }
    }
  }

  /// 列の `row` 行目（1 始まり、上から）の数字の字の左端（列の左から。字が無ければ nil）。
  private func inkLeft(_ opened: Opened, row: Int) throws -> CGFloat? {
    let view = opened.document.surface.view
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    let top = style.topInset + CGFloat(row - 1) * style.lineHeight
    return try stride(from: 0, to: style.gutterWidth, by: 0.5).first { x in
      try stride(from: top + 2, to: top + style.lineHeight - 2, by: 1).contains { y in
        let color = try XCTUnwrap(
          rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        return color.alphaComponent > 0.3
      }
    }
  }

  /// 番号は行索引の行に 1 つ——単独の `\r` で TextKit が割った段落（行索引では前の行の続き）には描かない。本文が改行で
  /// 終われば末尾の空行にも番号が付く。
  func testNumbersFollowTheLineIndexNotTheParagraphs() throws {
    let opened = try open("one\rtwo\nthree\n")
    XCTAssertEqual(opened.document.lineIndex.lineCount, 3, "前提: 行索引は \\r で割らない")
    XCTAssertEqual(
      try inkedRows(opened, count: 5), [true, false, true, true, false],
      "1（one）・番号なし（two）・2（three）・3（末尾の空行）")
  }

  /// 空の文書にも 1 行目の番号を描く（TextKit は空の文書に段落を作らない）。
  func testAnEmptyDocumentShowsLineOne() throws {
    let opened = try open("")
    XCTAssertEqual(try inkedRows(opened, count: 2), [true, false])
  }

  /// 縦にスクロールすると、番号は見えている行の番号に替わる——先頭の「1」（1 桁）が、100 行目を先頭へ送れば「100」
  /// （3 桁。右寄せなので字の左端が 2 桁ぶん左へ出る）になる。
  func testNumbersFollowVerticalScrolling() throws {
    let opened = try open(lines(300))
    let twoDigitsLeft = style.gutterWidth - style.gutterTrailingInset - digitsWidth("10")
    let first = try XCTUnwrap(try inkLeft(opened, row: 1), "前提: 先頭の行の番号")
    XCTAssertGreaterThan(first, twoDigitsLeft, "先頭の行は 1 桁")

    opened.document.scroll(toFirstLine: 99)
    pumpMain(until: { opened.document.viewportLines.first == 99 }, "100 行目が先頭に来る")
    let scrolled = try XCTUnwrap(try inkLeft(opened, row: 1), "送った先の番号")
    XCTAssertLessThan(scrolled, twoDigitsLeft, "先頭の行は 3 桁の 100")
  }

  /// 列は最大の行番号が収まる幅——最小の幅に収まる限り広がらず（10 万行の 6 桁も収まる）、桁が増えれば打鍵のその場で
  /// 広がり、本文はその右から始まる。
  func testTheColumnFitsTheWidestNumber() throws {
    let minimum = style.gutterWidth + style.marks.gutterWidth
    let trailing = style.gutterTrailingInset + style.marks.gutterWidth
    let long = try open(lines(99_999))
    XCTAssertEqual(long.document.lineIndex.lineCount, 100_000)
    XCTAssertGreaterThanOrEqual(long.column.frame.width, ceil(digitsWidth("100000")) + trailing)
    XCTAssertEqual(long.column.frame.width, minimum, "6 桁は最小の幅に収まる")

    // 最小の幅を 3 桁ぶんにした面で、999 行から 1000 行へ増やす。
    var narrow = style
    narrow.gutterWidth = ceil(digitsWidth("999")) + style.gutterTrailingInset
    let url = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("narrow.txt")
    try Data(lines(998).utf8).write(to: url)
    let surface = makeTextSurface(style: narrow, text: lines(998))
    let document = EditorDocument(
      url: url, contents: try EditorDocument.read(url), surface: surface,
      registry: LanguageRegistry(queriesRoot: nil))
    surface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    surface.view.layoutSubtreeIfNeeded()
    let column = try XCTUnwrap(surface.view.subviews.last)
    let scroll = try XCTUnwrap(surface.view.subviews.first)
    XCTAssertEqual(column.frame.width, narrow.gutterWidth + narrow.marks.gutterWidth, "999 行は収まる")
    surface.selectedRange = NSRange(location: 0, length: 0)
    surface.responder.insertText("\n")
    surface.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(document.lineIndex.lineCount, 1000)
    XCTAssertEqual(column.frame.width, ceil(digitsWidth("1000")) + trailing, "4 桁で広がる")
    XCTAssertEqual(scroll.frame.minX, column.frame.width, "本文は列の右から")
  }

  private func digitsWidth(_ digits: String) -> CGFloat {
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: digits, attributes: [.font: style.gutterFont]))
    return CTLineGetTypographicBounds(line, nil, nil, nil)
  }

  /// pane に載せても、番号と印の列の上の押下は列が受ける（上に重なる層が当たりを奪えば、番号を押しても行を選べず、印の列の
  /// 押下が本文へ抜けてキャレットが動く）。
  func testPressesOverTheColumnInThePaneReachTheColumn() throws {
    let hosted = try hostOverview(lines(50))
    let column = try XCTUnwrap(hosted.document.surface.view.subviews.last as? LineNumbersView)
    let root = try XCTUnwrap(hosted.window.contentView)
    for x in [20, column.bounds.width - style.marks.gutterWidth / 2] {
      let point = column.convert(
        NSPoint(x: x, y: column.bounds.minY + 2.5 * style.lineHeight), to: nil)
      XCTAssertIdentical(root.hitTest(point), column, "列の x=\(x)")
    }
  }

  /// 列の上のホイールは本文のスクロールへ届く（列がスクロールの死角にならない）。
  func testWheelOverTheColumnReachesTheTextScroll() throws {
    let opened = try open(lines(200))
    let container = try XCTUnwrap(opened.document.surface.view as? SurfaceContainerView)
    XCTAssertIdentical(container.scrollTarget, opened.scroll, "前提: 器の渡し先は本文のスクロール")
    let spy = WheelSpy()
    container.scrollTarget = spy
    let wheel = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -180, wheel2: 0,
        wheel3: 0))
    let event = try XCTUnwrap(NSEvent(cgEvent: wheel))
    opened.column.scrollWheel(with: event)
    XCTAssertIdentical(spy.received.last, event)
  }
}
