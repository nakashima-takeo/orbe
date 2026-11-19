import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 相手と同じ高さの空き——並列の diff で、片方の面のスレッドの反対側に置く空き。壊れると、スレッドの返信欄で改行したり
/// 幅を変えたりしたコマで左右の行がずれる、スレッドの高さが変わると片側だけ跳ねる、空きにキャレットが入る。
extension SurfaceSharedScrollTests {
  /// 左の面を 1 回出しただけで、描画スレッドが見る両面の並びの行 `line` が同じ y にある（左右の行が同じコマで揃う）。
  func assertAligned(
    _ a: Opened, _ b: Opened, after line: Int, _ message: String, file: StaticString = #filePath,
    lineNumber: UInt = #line
  ) {
    a.surface.flush()
    XCTAssertEqual(
      a.surface.material.read().rows.y(ofLine: line),
      b.surface.material.read().rows.y(ofLine: line),
      message, file: file, line: lineNumber)
  }

  /// 左の絵の差し込みの高さが変わる操作（描き直し・幅の変更・入力欄が伸びる）の後、同じ出す 1 回で右の空きが同じ高さになり、
  /// 左右の行が揃う。右が先に並びを置いても、左が後から置いた絵の高さに揃う。
  func testTheGapFollowsThePartnersZoneInTheSameFlush() throws {
    let (a, b) = try pair()
    let field = ZoneTextField(id: "reply", style: ThreadZone.fieldStyle())
    let thread = ThreadZone(comment: "左のスレッドの本文。", field: field)
    thread.surface = a.surface
    b.surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 10, content: .gap(thread))]))
    a.surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 10, content: .zone(thread))]))
    XCTAssertGreaterThan(a.surface.rows.heights[0], 0, "前提: 絵の差し込みに高さがある")
    assertAligned(a, b, after: 11, "後から置いた絵の高さに揃う")
    let before = a.surface.rows.heights[0]
    a.surface.focus(field)
    a.surface.textView.insertNewline(nil)
    XCTAssertGreaterThan(a.surface.rows.heights[0], before, "前提: 入力欄が伸びた")
    assertAligned(a, b, after: 11, "入力欄が伸びる")
    thread.comment = String(repeating: "幅が狭いと折り返す本文。", count: 6)
    a.surface.redrawZone(thread)
    assertAligned(a, b, after: 11, "描き直し")
    a.surface.viewStateDidChange(size: CGSize(width: 250, height: 300), scale: 2, visible: false)
    assertAligned(a, b, after: 11, "幅の変更")
    a.surface.setRows(SurfaceRows())
    XCTAssertEqual(b.surface.drawn.rows.heights, [0], "相手の面から外れれば 0")
  }

  /// 空きの高さが変わっても、両面で見えている先頭の行は動かない。
  func testAGapChangeKeepsTheFirstVisibleLineOnBothSurfaces() throws {
    let (a, b) = try pair()
    let box = BoxZone(height: 30.3)
    a.surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 10, content: .zone(box))]))
    b.surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 10, content: .gap(box))]))
    a.surface.scroll(to: RowPosition(line: 50))
    a.surface.flush()
    box.height = 61.7
    a.surface.redrawZone(box)
    a.surface.flush()
    XCTAssertEqual(a.surface.viewport.top, RowPosition(line: 50))
    XCTAssertEqual(b.surface.viewport.top, RowPosition(line: 50))
    XCTAssertEqual(a.surface.scrollPosition, b.surface.scrollPosition)
  }

  /// 同じ境の左右にそれぞれスレッドがあれば、互いの空きを置き合って左右とも 2 つの高さの和になり、どちらの高さが変わっても
  /// 揃ったまま（空きは絵の差し込みだけを写すので、互いを写し合って揺れない）。
  func testThreadsOnBothSidesOfOneBoundaryStayAligned() throws {
    let (a, b) = try pair()
    let left = BoxZone(height: 40)
    let right = BoxZone(height: 25)
    a.surface.setRows(
      SurfaceRows(insertions: [
        RowInsertion(line: 10, content: .zone(left)), RowInsertion(line: 10, content: .gap(right)),
      ]))
    b.surface.setRows(
      SurfaceRows(insertions: [
        RowInsertion(line: 10, content: .gap(left)), RowInsertion(line: 10, content: .zone(right)),
      ]))
    XCTAssertEqual(a.surface.drawn.rows.heights, [40, 25])
    XCTAssertEqual(b.surface.drawn.rows.heights, [40, 25])
    right.height = 70
    b.surface.redrawZone(right)
    XCTAssertEqual(a.surface.drawn.rows.heights, [40, 70])
    assertAligned(a, b, after: 11, "右の高さが変わっても揃う")
  }

  /// 空きは文書の行でも絵でもない——押すと次の文書の行の行頭に当たり（キャレットは空きに入らない）、何も描かない。
  func testTheGapIsNeitherSelectableNorDrawn() throws {
    let (a, b) = try pair()
    let box = BoxZone(height: 60)
    a.surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 4, content: .zone(box))]))
    b.surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 4, content: .gap(box))]))
    let surface = b.surface
    let y = surface.config.topInset + CGFloat(surface.rows.top(ofBlock: 0)) + 30
    let hit = try XCTUnwrap(surface.hit(CGPoint(x: surface.surfaceLayout.text.minX + 20, y: y)))
    XCTAssertEqual(hit.offset, b.document.text.lineStart(4))
    XCTAssertFalse(hit.onLine, "文書の行の上ではない")
    guard case .body = surface.target(at: CGPoint(x: surface.surfaceLayout.text.minX + 20, y: y))
    else { return XCTFail("空きは本文の、ほかに当たらない所と同じ") }
  }

  /// 相手が後から付けば空きは相手の絵の高さになり、相手が閉じれば 0 に戻る。
  func testTheGapFollowsThePartnerJoiningAndLeaving() throws {
    let b = try open(rows(120), size: CGSize(width: 400, height: 300))
    b.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    let box = BoxZone(height: 45)
    b.surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 10, content: .gap(box))]))
    XCTAssertEqual(b.surface.drawn.rows.heights, [0], "相手が無い間は 0")
    do {
      let a = try open(rows(200), size: CGSize(width: 400, height: 300))
      a.surface.setPresentation(SurfacePresentation(showsMinimap: false))
      a.surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 10, content: .zone(box))]))
      a.surface.shareScroll(with: b.surface)
      XCTAssertEqual(b.surface.drawn.rows.heights, [45], "相手が付けば相手の絵の高さ")
    }
    pump(until: { b.surface.partner == nil }, "前提: 相手が閉じれば外れる")
    XCTAssertEqual(b.surface.drawn.rows.heights, [0], "相手が閉じれば 0")
  }

  /// 空きが後から結ぶ面・先に結ぶ面・両面のどれにあっても、先に結ぶ面を行 50 に送ってから結べば、空きが相手の絵の高さに揃った後も
  /// 両面の見えている先頭の行は行 50 のまま。結んだまま相手が閉じて空きが 0 に戻っても、残った面の先頭の行は動かない。
  func testJoiningAndLeavingKeepTheFirstVisibleLine() throws {
    let top = RowPosition(line: 50)
    for (name, gapOnFirst, gapOnLater) in [
      ("後から結ぶ面に空き", false, true), ("先に結ぶ面に空き", true, false), ("両面に空き", true, true),
    ] {
      let a = try open(rows(200), size: CGSize(width: 400, height: 300))
      let b = try open(rows(120), size: CGSize(width: 400, height: 300))
      let (left, right) = (BoxZone(height: 45), BoxZone(height: 30))
      var first: [RowInsertion] = []
      var later: [RowInsertion] = []
      if gapOnLater {
        first.append(RowInsertion(line: 10, content: .zone(left)))
        later.append(RowInsertion(line: 10, content: .gap(left)))
      }
      if gapOnFirst {
        first.append(RowInsertion(line: 10, content: .gap(right)))
        later.append(RowInsertion(line: 10, content: .zone(right)))
      }
      for (opened, insertions) in [(a, first), (b, later)] {
        opened.surface.setPresentation(SurfacePresentation(showsMinimap: false))
        opened.surface.setRows(SurfaceRows(insertions: insertions))
      }
      a.surface.scroll(to: top)
      a.surface.flush()
      a.surface.shareScroll(with: b.surface)
      a.surface.flush()
      XCTAssertEqual(a.surface.viewport.top, top, "\(name): 先に結ぶ面")
      XCTAssertEqual(b.surface.viewport.top, top, "\(name): 後から結ぶ面")
    }
    let b = try open(rows(120), size: CGSize(width: 400, height: 300))
    b.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    let box = BoxZone(height: 45)
    b.surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 10, content: .gap(box))]))
    do {
      let a = try open(rows(200), size: CGSize(width: 400, height: 300))
      a.surface.setPresentation(SurfacePresentation(showsMinimap: false))
      a.surface.setRows(SurfaceRows(insertions: [RowInsertion(line: 10, content: .zone(box))]))
      a.surface.shareScroll(with: b.surface)
      a.surface.scroll(to: top)
      a.surface.flush()
      XCTAssertEqual(b.surface.viewport.top, top, "前提: 結んだまま行 50")
    }
    pump(until: { b.surface.partner == nil }, "前提: 相手が閉じれば外れる")
    b.surface.flush()
    XCTAssertEqual(b.surface.drawn.rows.heights, [0], "前提: 空きは 0 に戻る")
    XCTAssertEqual(b.surface.viewport.top, top, "相手が閉じた後")
  }
}
