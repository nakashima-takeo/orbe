import AppKit
import OrbeEditorCore

/// 俯瞰の上の押下・ドラッグ・ホバー（main 側）。当たりは面の区画の配置で決め、ミニマップの押下と帯のドラッグの起点は
/// 最後に描いた配置で解き（描いたとおりに当たる）、縦横のつまみとトラックは今の状態から `ScrollbarGeometry` で解く。
/// 位置は Core の式で出して置き、ドラッグの出来事の処理の終わりで出す（面の入力）。ホバーとドラッグの種類は操作の状態として
/// 材料に書き、帯・つまみの上かと濃さは描画スレッドが決める。
@MainActor
final class OverviewPointer {
  weak var surface: MetalTextSurface?

  /// 俯瞰の区画。
  enum Area {
    case minimap, vertical, horizontal
  }

  private enum Drag {
    case minimap(startY: CGFloat, placement: MinimapLayout)
    case vertical(start: CGFloat, geometry: ScrollbarGeometry)
    case horizontal(start: CGFloat, geometry: ScrollbarGeometry)
  }

  private var drag: Drag?
  /// 材料に書いた操作の状態。
  private var input = OverviewInput()

  /// ドラッグ中か。
  var isDragging: Bool { drag != nil }

  /// 点（view の座標、pt）の上の俯瞰の区画。横スクロールバーは横に続く本文があるときだけ。
  func area(at point: CGPoint) -> Area? {
    guard let surface else { return nil }
    let layout = surface.surfaceLayout
    if layout.verticalScrollbar.contains(point) { return .vertical }
    if layout.minimap.contains(point) { return .minimap }
    if layout.horizontalScrollbar.contains(point), surface.scrollState().limits.maximum.x > 0 {
      return .horizontal
    }
    return nil
  }

  /// 俯瞰の上の押下なら扱って true。ミニマップは帯の中なら掴み、外ならその行の上端を中央へ（ドラッグは続かない）。
  /// スクロールバーはつまみの中なら掴み、トラックならつまみの中央がそこへ来るよう飛んで、飛んだ後の状態を起点に同じ
  /// 押下のままドラッグへ移る。
  func mouseDown(at point: CGPoint) -> Bool {
    guard let surface, let area = area(at: point) else { return false }
    let layout = surface.surfaceLayout
    switch area {
    case .minimap:
      guard let placement = surface.placementBox.read() else { return true }
      let y = point.y - layout.minimap.minY
      if placement.sliderContains(y: y) {
        drag = .minimap(startY: y, placement: placement)
      } else {
        // VS Code の revealRange の Center はマウスでは 1 行上まで含めた箱の中央＝行の上端。横位置は動かさない。
        surface.scroll(
          toFirstLine: CGFloat(placement.line(atY: y)) - surface.viewportLines.visible / 2)
      }
    case .vertical:
      var geometry = verticalGeometry(layout)
      guard geometry.isNeeded else { return true }
      let y = point.y - layout.verticalScrollbar.minY
      if !geometry.sliderContains(y) {
        surface.scroll(toFirstLine: geometry.position(centeringSliderAt: y))
        geometry = verticalGeometry(layout)
      }
      drag = .vertical(start: y, geometry: geometry)
    case .horizontal:
      var geometry = horizontalGeometry(layout)
      guard geometry.isNeeded else { return true }
      let x = point.x - layout.horizontalScrollbar.minX
      if !geometry.sliderContains(x) {
        surface.scroll(toX: geometry.position(centeringSliderAt: x))
        geometry = horizontalGeometry(layout)
      }
      drag = .horizontal(start: x, geometry: geometry)
    }
    update(point: point)
    return true
  }

  /// 俯瞰のドラッグ中なら動かして true。
  func mouseDragged(to point: CGPoint) -> Bool {
    guard let surface, let drag else { return false }
    let layout = surface.surfaceLayout
    switch drag {
    case .minimap(let start, let placement):
      let y = point.y - layout.minimap.minY
      surface.scroll(toFirstLine: placement.firstLine(afterDragging: y - start))
    case .vertical(let start, let geometry):
      let y = point.y - layout.verticalScrollbar.minY
      surface.scroll(toFirstLine: geometry.position(afterDragging: y - start))
    case .horizontal(let start, let geometry):
      let x = point.x - layout.horizontalScrollbar.minX
      surface.scroll(toX: geometry.position(afterDragging: x - start))
    }
    update(point: point)
    return true
  }

  /// 俯瞰のドラッグを離したなら true。
  func mouseUp(at point: CGPoint) -> Bool {
    guard drag != nil else { return false }
    drag = nil
    update(point: point)
    return true
  }

  /// ポインタが動いた・面に入った（`inside`）・面から出た。
  func pointerMoved(to point: CGPoint, inside: Bool) {
    input.hovering = inside
    update(point: point)
  }

  /// 押している間に窓から外れた。
  func cancel() {
    drag = nil
    input.hovering = false
    update(point: nil)
  }

  /// 動きを減らす設定。
  func setReduceMotion(_ reduce: Bool) {
    guard reduce != input.reduceMotion else { return }
    input.reduceMotion = reduce
    write()
  }

  /// 操作の状態を材料に書く（変わったときだけ。ポインタの位置は俯瞰の上にあるときだけ持つ）。
  private func update(point: CGPoint?) {
    input.pointer = point.flatMap { area(at: $0) != nil ? $0 : nil }
    input.drag =
      switch drag {
      case .minimap: .minimap
      case .vertical: .vertical
      case .horizontal: .horizontal
      case nil: nil
      }
    write()
  }

  private var written = OverviewInput()

  private func write() {
    guard input != written, let surface else { return }
    written = input
    let input = input
    surface.write { $0.overview = input }
  }

  private func verticalGeometry(_ layout: SurfaceLayout) -> ScrollbarGeometry {
    guard let surface else {
      return ScrollbarGeometry(visible: 0, total: 0, position: 0, trackLength: 0)
    }
    let lines = surface.viewportLines
    return ScrollbarGeometry(
      lineCount: surface.currentContent?.text.lineCount ?? 1, firstLine: lines.first,
      visibleLines: lines.visible, height: layout.verticalScrollbar.height)
  }

  private func horizontalGeometry(_ layout: SurfaceLayout) -> ScrollbarGeometry {
    guard let surface else {
      return ScrollbarGeometry(visible: 0, total: 0, position: 0, trackLength: 0)
    }
    let (position, limits) = surface.scrollState()
    return ScrollbarGeometry(
      visible: limits.viewport.x, total: limits.viewport.x + limits.maximum.x,
      position: min(max(0, position.x), limits.maximum.x),
      trackLength: layout.horizontalScrollbar.width)
  }
}
