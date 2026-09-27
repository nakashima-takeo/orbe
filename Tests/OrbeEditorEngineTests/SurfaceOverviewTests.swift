import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面の俯瞰の操作——ミニマップの帯のドラッグ・帯の外の押下、縦横のスクロールバーのつまみとトラック、ホバーで
/// 現れる帯とつまみ、俯瞰の上のポインタ（今の面の俯瞰と同じ規則）。壊れると帯を掴めない・押した行が中央に来ない・
/// トラックを押しても飛ばない・横に動かない・俯瞰の上で文字が選ばれる。
@MainActor
final class SurfaceOverviewTests: EngineTestCase {
  private func rows(_ count: Int, width: Int = 10) -> String {
    (0..<count).map { "row \($0) " + String(repeating: "x", count: width) }.joined(separator: "\n")
      + "\n"
  }

  /// 描き終えた状態で、帯とつまみが時間を掛けずに現れる（動きを減らす設定）面。
  private func hosted(_ text: String, size: CGSize = CGSize(width: 800, height: 400)) throws
    -> Opened
  {
    let opened = try open(text, size: size)
    _ = host(opened, size: size)
    opened.surface.inputScope { opened.surface.textView.overview.setReduceMotion(true) }
    _ = opened.surface.snapshot()
    return opened
  }

  /// ミニマップの帯の外を押すとその行の上端が本文の中央に来て、横位置は動かない。
  func testPressingTheMinimapOutsideTheSliderCentersThatLine() throws {
    let opened = try hosted(rows(2000))
    let area = opened.surface.surfaceLayout.minimap
    try mouse(opened, .leftMouseDown, at: CGPoint(x: area.midX, y: 300))
    try mouse(opened, .leftMouseUp, at: CGPoint(x: area.midX, y: 300))
    let placement = try XCTUnwrap(opened.surface.placementBox.read())
    let line = CGFloat(placement.line(atY: 300))
    let lines = opened.surface.viewportLines
    XCTAssertEqual(lines.first + lines.visible / 2, line, accuracy: 1e-6)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 0), "選択は動かない")
  }

  /// 帯を掴んでドラッグすると、押したときの配置の式で本文がそのまま追従する。
  func testDraggingTheSliderMovesTheText() throws {
    let opened = try hosted(rows(2000))
    let area = opened.surface.surfaceLayout.minimap
    let placement = try XCTUnwrap(opened.surface.placementBox.read())
    let grab = CGPoint(x: area.midX, y: placement.sliderTop + placement.sliderHeight / 2)
    try mouse(opened, .leftMouseDown, at: grab)
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: grab.x, y: grab.y + 50))
    XCTAssertEqual(
      opened.surface.viewportLines.first, placement.firstLine(afterDragging: 50), accuracy: 1e-6)
    XCTAssertEqual(opened.surface.drawn.overview.drag, .minimap, "ドラッグ中は帯を濃く描く")
    try mouse(opened, .leftMouseUp, at: CGPoint(x: grab.x, y: grab.y + 50))
    XCTAssertNil(opened.surface.drawn.overview.drag)
  }

  /// トラックを押すとつまみの中央がそこへ飛び、同じ押下のままドラッグへ移る。
  func testTheVerticalTrackJumpsAndDragsOn() throws {
    let opened = try hosted(rows(2000))
    let bar = opened.surface.surfaceLayout.verticalScrollbar
    let lines = opened.surface.viewportLines
    let before = ScrollbarGeometry(
      lineCount: 2001, firstLine: lines.first, visibleLines: lines.visible, height: bar.height)
    try mouse(opened, .leftMouseDown, at: CGPoint(x: bar.midX, y: 250))
    XCTAssertEqual(
      opened.surface.viewportLines.first, before.position(centeringSliderAt: 250), accuracy: 1e-6)
    let jumped = ScrollbarGeometry(
      lineCount: 2001, firstLine: opened.surface.viewportLines.first, visibleLines: lines.visible,
      height: bar.height)
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: bar.midX, y: 210))
    XCTAssertEqual(
      opened.surface.viewportLines.first, jumped.position(afterDragging: -40), accuracy: 1e-6)
    try mouse(opened, .leftMouseUp, at: CGPoint(x: bar.midX, y: 210))
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 0), "俯瞰の上では選ばない")
  }

  /// 横に続く本文があるときだけ横スクロールバーがあり、トラックの押下とドラッグで横に動く（縦は動かない）。
  func testTheHorizontalScrollbarMovesSideways() throws {
    let opened = try hosted(rows(40, width: 400))
    let bar = opened.surface.surfaceLayout.horizontalScrollbar
    let (position, limits) = opened.surface.scrollState()
    XCTAssertGreaterThan(limits.maximum.x, 0, "前提: 横に続く")
    let before = ScrollbarGeometry(
      visible: limits.viewport.x, total: limits.viewport.x + limits.maximum.x,
      position: position.x, trackLength: bar.width)
    let at = CGPoint(x: bar.minX + 300, y: bar.midY)
    try mouse(opened, .leftMouseDown, at: at)
    XCTAssertEqual(
      opened.surface.scrollPosition.x, before.position(centeringSliderAt: 300), accuracy: 1e-6)
    XCTAssertEqual(opened.surface.scrollPosition.y, 0)
    try mouse(opened, .leftMouseUp, at: at)
    let short = try hosted(rows(40))
    let area = short.surface.surfaceLayout.horizontalScrollbar
    XCTAssertNil(
      short.surface.textView.overview.area(at: CGPoint(x: area.minX + 20, y: area.midY)),
      "横に続かなければ横スクロールバーは無い（本文として押せる）")
  }

  /// 本体の上にポインタがあるとつまみが見え、ミニマップの上なら帯が見える。俯瞰の上のポインタは矢印。
  func testHoveringShowsTheThumbAndTheSlider() throws {
    let opened = try hosted(rows(2000))
    let layout = opened.surface.surfaceLayout
    let view = opened.surface.textView
    let thumbColor = { (shot: PixelShot) in
      shot.rgb(layout.verticalScrollbar.midX, 10)
    }
    let idle = try pixelShot(opened)
    XCTAssertEqual(thumbColor(idle), [0, 0, 0], "普段はつまみが無い")
    opened.surface.inputScope {
      view.overview.pointerMoved(to: CGPoint(x: layout.minimap.midX, y: 100), inside: true)
    }
    let hovering = try pixelShot(opened)
    XCTAssertNotEqual(thumbColor(hovering), [0, 0, 0], "本体の上ではつまみが見える")
    let placement = try XCTUnwrap(opened.surface.placementBox.read())
    XCTAssertTrue(
      hovering.hasInk(layout.minimap.maxX - 2, placement.sliderTop + 1), "ミニマップの上では帯が見える")
    opened.surface.inputScope {
      view.overview.pointerMoved(to: CGPoint(x: -10, y: -10), inside: false)
    }
    let left = try pixelShot(opened)
    XCTAssertEqual(thumbColor(left), [0, 0, 0], "本体から出ると消える（動きを減らす設定では時間を掛けない）")
  }
}

/// 帯とつまみの濃さの時間の動き（VS Code の既定: 100ms で現れ、スクロールが止まって 500ms 後に 800ms で消える）。
@MainActor
final class OverviewMotionTests: XCTestCase {
  private let motion = SurfaceConfig.Overview(EngineTestCase.overviewStyle())

  private func state(_ first: CGFloat) -> OverviewMotion.ScrollState {
    OverviewMotion.ScrollState(
      first: first, visible: 20, lineCount: 100, x: 0, width: 500, range: 0)
  }

  func testTheThumbAppearsOnScrollAndFadesAfterTheDelay() {
    let m = OverviewMotion()
    let idle = OverviewInput()
    XCTAssertEqual(
      m.thumbOpacity(at: 0, state: state(0), input: idle, motion: motion), 0, "最初のコマは数えない")
    XCTAssertEqual(
      m.thumbOpacity(at: 1, state: state(5), input: idle, motion: motion), 0, "変わった刻みは 0 から")
    XCTAssertEqual(
      m.thumbOpacity(at: 1.05, state: state(5), input: idle, motion: motion), 0.5, accuracy: 1e-9)
    XCTAssertEqual(m.wakeAt ?? 0, 1.5, accuracy: 1e-9, "止まって 500ms 後に起きる")
    XCTAssertEqual(m.thumbOpacity(at: 1.4, state: state(5), input: idle, motion: motion), 1)
    XCTAssertFalse(m.animating)
    XCTAssertEqual(m.thumbOpacity(at: 1.5, state: state(5), input: idle, motion: motion), 1, "消え始め")
    XCTAssertEqual(
      m.thumbOpacity(at: 1.9, state: state(5), input: idle, motion: motion), 0.5, accuracy: 1e-9)
    XCTAssertTrue(m.animating)
    XCTAssertEqual(m.thumbOpacity(at: 2.3, state: state(5), input: idle, motion: motion), 0)
    XCTAssertFalse(m.animating, "消え終われば止まる")
    XCTAssertNil(m.wakeAt, "消え終われば起きない")
  }

  func testHoveringKeepsTheThumbAndLeavingHidesItAtOnce() {
    let m = OverviewMotion()
    var input = OverviewInput()
    input.hovering = true
    _ = m.thumbOpacity(at: 0, state: state(0), input: input, motion: motion)
    XCTAssertEqual(m.thumbOpacity(at: 5, state: state(3), input: input, motion: motion), 1)
    XCTAssertNil(m.wakeAt, "上にある間は消えない")
    input.hovering = false
    XCTAssertEqual(
      m.thumbOpacity(at: 5.1, state: state(3), input: input, motion: motion), 1, "出た刻みから消え始める")
    XCTAssertEqual(
      m.thumbOpacity(at: 5.5, state: state(3), input: input, motion: motion), 0.5, accuracy: 1e-9)
  }
}
