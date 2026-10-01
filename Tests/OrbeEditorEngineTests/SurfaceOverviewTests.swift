import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 面の俯瞰の操作——ミニマップの帯のドラッグ・帯の外の押下、縦横のスクロールバーのつまみとトラック、ホバーで
/// 現れる帯とつまみ、俯瞰の上のポインタ（VS Code と同じ規則）。壊れると帯を掴めない・押した行が中央に来ない・
/// トラックを押しても飛ばない・横に動かない・俯瞰の上で文字が選ばれる。
@MainActor
final class SurfaceOverviewTests: EngineTestCase {
  /// ミニマップの帯の外を押すとその行の上端が本文の中央に来て、横位置は動かない。押したままドラッグしても本文は動かない
  /// （帯を掴んだのではない）。
  func testPressingTheMinimapOutsideTheSliderCentersThatLine() throws {
    let opened = try hosted(rows(2000, width: 400))
    opened.surface.scroll(toX: 300)
    XCTAssertEqual(opened.surface.scrollPosition.x, 300, "前提: 横へ送った")
    let area = opened.surface.surfaceLayout.minimap
    let placement = try XCTUnwrap(opened.surface.placementBox.read())
    let press = CGPoint(x: area.midX, y: 300)
    XCTAssertFalse(placement.sliderContains(y: press.y - area.minY), "前提: 帯の外")
    try mouse(opened, .leftMouseDown, at: press)
    let lines = opened.surface.viewportLines
    XCTAssertEqual(
      lines.first + lines.visible / 2, CGFloat(placement.line(atY: press.y - area.minY)),
      accuracy: 1e-6)
    XCTAssertEqual(opened.surface.scrollPosition.x, 300, "横位置は動かない")
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: press.x, y: press.y + 60))
    try mouse(opened, .leftMouseUp, at: CGPoint(x: press.x, y: press.y + 60))
    XCTAssertEqual(opened.surface.viewportLines.first, lines.first, "続くドラッグでは動かない")
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

  /// 横に続く本文があるときだけ横スクロールバーがあり、トラックを押すとつまみの中央がそこへ飛び、そのままドラッグで横に
  /// 動く（縦は動かない）。
  func testTheHorizontalScrollbarMovesSideways() throws {
    let opened = try hosted(rows(10, width: 400))
    let bar = opened.surface.surfaceLayout.horizontalScrollbar
    XCTAssertGreaterThan(opened.surface.scrollState().limits.maximum.x, 0, "前提: 横に続く")
    let thumbCenter = { () throws -> CGFloat? in
      let shot = try self.pixelShot(opened)
      let inked = stride(from: bar.minX, to: bar.maxX, by: 0.5).filter {
        shot.hasInk($0, bar.midY)
      }
      guard let first = inked.first, let last = inked.last else { return nil }
      return (first + last + 0.5) / 2 - bar.minX
    }
    let at = CGPoint(x: bar.minX + 300, y: bar.midY)
    try mouse(opened, .leftMouseDown, at: at)
    XCTAssertEqual(try XCTUnwrap(thumbCenter()), 300, accuracy: 1, "つまみの中央が押した所へ飛ぶ")
    XCTAssertGreaterThan(opened.surface.scrollPosition.x, 0)
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: at.x + 50, y: at.y))
    XCTAssertEqual(try XCTUnwrap(thumbCenter()), 350, accuracy: 1, "そのままドラッグで付いてくる")
    XCTAssertEqual(opened.surface.scrollPosition.y, 0, "縦は動かない")
    try mouse(opened, .leftMouseUp, at: CGPoint(x: at.x + 50, y: at.y))
    let short = try hosted(rows(40))
    let area = short.surface.surfaceLayout.horizontalScrollbar
    XCTAssertNil(
      short.surface.textView.overview.area(at: CGPoint(x: area.minX + 20, y: area.midY)),
      "横に続かなければ横スクロールバーは無い（本文として押せる）")
  }

  /// 落とすドラッグは、本文に重なる下端の横スクロールバーの上でも帯の中なら自動でスクロールし、右列の上では送らず、右列
  /// から帯へ戻った最初の出来事は時刻を取るだけ（右列の上にいた時間ぶん跳ばない）。
  func testDropAutoscrollRunsOverTheHorizontalBarButNotOverTheRightColumn() throws {
    let opened = try hosted(rows(400, width: 400))
    let view = opened.surface.textView
    let layout = opened.surface.surfaceLayout
    let board = NSPasteboard(name: NSPasteboard.Name("dev.orbe.test.\(UUID().uuidString)"))
    addTeardownBlock { board.releaseGlobally() }
    board.clearContents()
    board.setString("x", forType: .string)
    let bar = layout.horizontalScrollbar
    let onBar = CGPoint(x: bar.minX + 100, y: bar.midY)
    XCTAssertEqual(view.overview.area(at: onBar), .horizontal, "前提: 下端の帯の中の横スクロールバー")
    let drag = FakeDraggingInfo(at: view.convert(onBar, to: nil), pasteboard: board)
    _ = view.draggingEntered(drag)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    _ = view.draggingUpdated(drag)
    XCTAssertGreaterThan(opened.surface.scrollPosition.y, 0, "横スクロールバーの上でも送る")

    drag.draggingLocation = view.convert(
      CGPoint(x: layout.minimap.midX, y: bar.midY), to: nil)
    let before = opened.surface.scrollPosition.y
    _ = view.draggingUpdated(drag)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    _ = view.draggingUpdated(drag)
    XCTAssertEqual(opened.surface.scrollPosition.y, before, "右列の上では送らない")
    drag.draggingLocation = view.convert(onBar, to: nil)
    _ = view.draggingUpdated(drag)
    XCTAssertEqual(opened.surface.scrollPosition.y, before, "戻った最初の出来事は時刻を取るだけ")
    view.draggingExited(drag)
  }

  /// 端を越えた位置（弾性で引っ張っている間）のコマでも、俯瞰（ミニマップの配置・帯・縦横のスクロールバーとつまみ・影）は
  /// 端の位置のコマと同じで、本文だけが動く——どのコマも俯瞰は同じコマの位置から出て、端を越える間は端を表す。
  func testTheOverviewStaysAtTheEdgeWhileTheTextIsPastIt() throws {
    let opened = try hosted(String(rows(400, width: 400).dropLast()))
    let minimap = opened.surface.surfaceLayout.minimap
    opened.surface.inputScope {
      opened.surface.textView.overview.pointerMoved(
        to: CGPoint(x: minimap.midX, y: 100), inside: true)
    }
    let maximum = opened.surface.scrollState().limits.maximum
    XCTAssertGreaterThan(maximum.x, 0, "前提: 横に続く")
    let cases: [(past: SIMD2<Double>, edge: SIMD2<Double>)] = [
      (SIMD2(0, -200), SIMD2(0, 0)), (SIMD2(0, maximum.y + 300), SIMD2(0, maximum.y)),
      (SIMD2(-150, 0), SIMD2(0, 0)), (SIMD2(maximum.x + 150, 0), SIMD2(maximum.x, 0)),
    ]
    for (past, edge) in cases {
      let beyond = try built(opened, at: past)
      let atEdge = try built(opened, at: edge)
      XCTAssertEqual(beyond.overview, atEdge.overview, "\(past) の俯瞰は \(edge) と同じ")
      XCTAssertNotEqual(beyond.text, atEdge.text, "前提: \(past) の本文は動いている")
    }
  }

  /// 引っ張った途中のコマ（指を離す前）を撮ると、俯瞰の列（ミニマップ・縦スクロールバー）は先頭のコマと同じ画素で、本文
  /// だけが下へずれている。
  func testAFramePulledPastTheTopShowsTheOverviewAtTheTop() throws {
    let opened = try hosted(rows(400, width: 400))
    let layout = opened.surface.surfaceLayout
    opened.surface.inputScope {
      opened.surface.textView.overview.pointerMoved(
        to: CGPoint(x: layout.minimap.midX, y: 100), inside: true)
    }
    let rest = try pixelShot(opened)
    let now = CACurrentMediaTime()
    opened.surface.scroll(
      ScrollInput(timestamp: now, delta: SIMD2(0, 0), precise: true, phase: .began))
    opened.surface.scroll(
      ScrollInput(timestamp: now + 0.01, delta: SIMD2(0, 200), precise: true, phase: .changed))
    XCTAssertLessThan(opened.surface.scroll.peek(at: now + 0.01).position.y, 0, "前提: 先頭より上")
    let pulled = try pixelShot(opened)
    var overview = 0
    var body = 0
    for y in stride(from: CGFloat(1), to: layout.minimap.maxY - 1, by: 1) {
      for x in stride(from: layout.minimap.minX + 1, to: layout.verticalScrollbar.maxX - 1, by: 1) {
        overview += pulled.rgb(x, y) == rest.rgb(x, y) ? 0 : 1
      }
      for x in stride(from: layout.text.minX + 1, to: layout.text.minX + 200, by: 2) {
        body += pulled.rgb(x, y) == rest.rgb(x, y) ? 0 : 1
      }
    }
    XCTAssertEqual(overview, 0, "俯瞰の列は先頭のコマと同じ")
    XCTAssertGreaterThan(body, 100, "前提: 本文はずれている")
    opened.surface.scroll(
      ScrollInput(timestamp: now + 0.02, delta: SIMD2(0, 0), precise: true, phase: .ended))
  }

  /// 組んだコマの俯瞰の図形と配置。
  private struct BuiltOverview: Equatable {
    var placement: MinimapLayout?
    var shapes: [SIMD4<Float>]
    var colors: [UInt32]
  }

  /// 組んだコマの俯瞰と、本文の字の位置（比べるため）。
  private struct Built: Equatable {
    var overview: BuiltOverview
    var text: [SIMD2<Float>]
  }

  /// 面の今の材料で、位置 `position` のコマを別の組み立て役で組む（描かない。面の刻みの状態に触れない）。
  private func built(_ opened: Opened, at position: SIMD2<Double>) throws -> Built {
    let id = opened.surface.id
    opened.surface.flush()
    return try XCTUnwrap(
      RenderThread.shared.performAndWait { renderer -> Built? in
        guard let slot = renderer.slot(id) else { return nil }
        let material = slot.material.read()
        guard let content = material.content else { return nil }
        let builder = FrameBuilder()
        let cache = LineLayoutCache()
        cache.beginFrame(version: content.version, tabColumns: material.tabColumns)
        builder.build(
          FrameBuilder.Source(
            material: material, position: position, limits: slot.scroll.peek(at: 0).limits,
            caretVisible: false, pixels: Renderer.pixelSize(material),
            atlas: renderer.atlas(scale: material.scale, space: material.space),
            config: slot.config, minimapCells: slot.minimapCells, rulerRows: slot.rulerRows,
            motion: OverviewMotion(), time: 0, baselines: 0, previousPlacement: nil),
          cache: cache, fonts: renderer.fonts)
        let shapes = builder.overviewShapes + builder.shadowShapes
        return Built(
          overview: BuiltOverview(
            placement: builder.minimap.placement, shapes: shapes.map(\.rect),
            colors: shapes.map(\.color)),
          text: builder.text.flatMap { $0.map(\.position) })
      })
  }

  /// 俯瞰の区画の上で当たるのは焦点を取らない子 view で（押しても窓は焦点を面へ移さない）、押下とドラッグは面の俯瞰へ
  /// 届く。本文の上は面の view が当たる。ポインタの形とホバーは今までどおり面の view の見張り（俯瞰の上も覆う）が決める
  /// ——子 view は見張りを持たず、俯瞰の上の当たりは矢印の区画。
  func testTheOverviewIsPressedWithoutTakingTheFocus() throws {
    let opened = try hosted(rows(400, width: 400))
    let view = opened.surface.textView
    let layout = opened.surface.surfaceLayout
    let hit = { (point: CGPoint) in view.hitTest(view.convert(point, to: view.superview)) }
    let areas = [
      CGPoint(x: layout.minimap.midX, y: 300), CGPoint(x: layout.verticalScrollbar.midX, y: 300),
      CGPoint(x: layout.horizontalScrollbar.minX + 100, y: layout.horizontalScrollbar.midY),
    ]
    for point in areas {
      let target = try XCTUnwrap(hit(point), "\(point)")
      XCTAssertTrue(target !== view && target.isDescendant(of: view), "\(point) は子 view が当たる")
      XCTAssertFalse(target.acceptsFirstResponder, "\(point) を押しても焦点を取らない")
      XCTAssertTrue(target.trackingAreas.isEmpty, "子 view は見張りを持たない")
      XCTAssertEqual(opened.surface.hit(point)?.area, .overview, "\(point) のポインタは矢印")
    }
    view.updateTrackingAreas()
    let watch = try XCTUnwrap(view.trackingAreas.first { $0.owner === view })
    XCTAssertTrue(
      watch.options.isSuperset(of: [
        .inVisibleRect, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited,
      ]),
      "面の view の見張りが俯瞰の上も覆う")
    XCTAssertTrue(hit(CGPoint(x: layout.text.minX + 50, y: 100)) === view, "本文の上は面の view")

    let target = try XCTUnwrap(hit(areas[1]))
    let before = opened.surface.viewportLines.first
    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: view.convert(areas[1], to: nil), modifierFlags: [],
        timestamp: CACurrentMediaTime(), windowNumber: view.window?.windowNumber ?? 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    target.mouseDown(with: event)
    XCTAssertGreaterThan(opened.surface.viewportLines.first, before, "トラックの押下が俯瞰へ届く")
    target.mouseUp(with: event)
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
    let after = try XCTUnwrap(opened.surface.placementBox.read())
    XCTAssertFalse(left.hasInk(layout.minimap.maxX - 2, after.sliderTop + 1), "帯も消える")
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
      m.thumbOpacity(at: 0, state: state(0), baselines: 0, input: idle, motion: motion), 0,
      "最初のコマは数えない")
    XCTAssertEqual(
      m.thumbOpacity(at: 1, state: state(5), baselines: 0, input: idle, motion: motion), 0,
      "変わった刻みは 0 から")
    XCTAssertEqual(
      m.thumbOpacity(at: 1.05, state: state(5), baselines: 0, input: idle, motion: motion), 0.5,
      accuracy: 1e-9)
    XCTAssertEqual(m.wakeAt ?? 0, 1.5, accuracy: 1e-9, "止まって 500ms 後に起きる")
    XCTAssertEqual(
      m.thumbOpacity(at: 1.4, state: state(5), baselines: 0, input: idle, motion: motion), 1)
    XCTAssertFalse(m.animating)
    XCTAssertEqual(
      m.thumbOpacity(at: 1.5, state: state(5), baselines: 0, input: idle, motion: motion), 1, "消え始め"
    )
    XCTAssertEqual(
      m.thumbOpacity(at: 1.9, state: state(5), baselines: 0, input: idle, motion: motion), 0.5,
      accuracy: 1e-9)
    XCTAssertTrue(m.animating)
    XCTAssertEqual(
      m.thumbOpacity(at: 2.3, state: state(5), baselines: 0, input: idle, motion: motion), 0)
    XCTAssertFalse(m.animating, "消え終われば止まる")
    XCTAssertNil(m.wakeAt, "消え終われば起きない")
  }

  /// 横の範囲の基準を取り直した測定（初めて測った・測り直した）による範囲の変化はつまみを出さず、それ以外の範囲の変化
  /// （打鍵で行が伸びた）は出す。
  func testARebasedRangeDoesNotShowTheThumb() {
    let m = OverviewMotion()
    let idle = OverviewInput()
    var wide = state(0)
    _ = m.thumbOpacity(at: 0, state: state(0), baselines: 0, input: idle, motion: motion)
    wide.range = 300
    _ = m.thumbOpacity(at: 1, state: wide, baselines: 1, input: idle, motion: motion)
    XCTAssertNil(m.wakeAt, "初めて測った範囲では出ない")
    wide.range = 400
    _ = m.thumbOpacity(at: 2, state: wide, baselines: 1, input: idle, motion: motion)
    XCTAssertNotNil(m.wakeAt, "その後の範囲の変化では出る")
  }

  func testHoveringKeepsTheThumbAndLeavingHidesItAtOnce() {
    let m = OverviewMotion()
    var input = OverviewInput()
    input.hovering = true
    _ = m.thumbOpacity(at: 0, state: state(0), baselines: 0, input: input, motion: motion)
    XCTAssertEqual(
      m.thumbOpacity(at: 5, state: state(3), baselines: 0, input: input, motion: motion), 1)
    XCTAssertNil(m.wakeAt, "上にある間は消えない")
    input.hovering = false
    XCTAssertEqual(
      m.thumbOpacity(at: 5.1, state: state(3), baselines: 0, input: input, motion: motion), 1,
      "出た刻みから消え始める")
    XCTAssertEqual(
      m.thumbOpacity(at: 5.5, state: state(3), baselines: 0, input: input, motion: motion), 0.5,
      accuracy: 1e-9)
  }
}

/// スクロールバーの印の元——検索の一致を行へ写した結果は、本文の編集でずらして使い回し、写し直すのは区間の列が本当に
/// 変わったときだけ（打鍵のたびに 19999 件を写し直さない）。
final class RulerRowsTests: XCTestCase {
  func testTheRowsAreShiftedByEditsAndRemappedOnlyWhenTheRangesChange() {
    let rows = RulerRows()
    var text = TextRope("a x\nb x\nc x\n")
    var highlights = Highlights()
    highlights.find = [NSRange(location: 2, length: 1), NSRange(location: 6, length: 1)]
    XCTAssertEqual(rows.find(highlights, text: text).rows, [0...0, 1...1])
    XCTAssertEqual(rows.remappedInFrame, 2)
    let edit = TextEdit(range: NSRange(location: 0, length: 0), replacement: "z\n")
    rows.receive([RowEdit(edit, in: text, version: 1)])
    text.replace(edit.range, with: edit.replacement)
    highlights.find = edit.track(highlights.find)
    XCTAssertEqual(rows.find(highlights, text: text).rows, [1...1, 2...2], "改行の分だけ下へずらす")
    XCTAssertEqual(rows.remappedInFrame, 0, "ずらした列と同じなら写し直さない")
    highlights.find = [NSRange(location: 10, length: 1)]
    XCTAssertEqual(rows.find(highlights, text: text).rows, [3...3])
    XCTAssertEqual(rows.remappedInFrame, 1, "検索語を変えれば写し直す")
  }
}
