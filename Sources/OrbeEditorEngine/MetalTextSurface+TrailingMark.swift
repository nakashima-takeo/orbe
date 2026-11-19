import AppKit
import OrbeEditorCore

/// 行の右端の印を描く材料——印の絵（ポインタが印の上なら、その上の見え方）と、描く行・大きさ・本文の区画の右端からの距離。
struct TrailingMarkMaterial: Sendable {
  var look: ZoneMaterial
  var row: TrailingMarkRow
  var size: CGSize
  var inset: CGFloat
}

/// ポインタが乗っている、印を出せる行と、ポインタが印の上か。
struct TrailingMarkHover: Equatable {
  var row: TrailingMarkRow
  var line: TrailingMarkLine
  var onMark: Bool
}

/// 行の右端の印——表示の構成が印の絵を持ち、並びが印を出せる行を持つ面で、ポインタが乗った行の右端に印を描き、押下を
/// 並びの受け手へ知らせる。印の出し入れは材料の 1 欄の書き換えだけで、行も絵の差し込みも描き直さない。
extension MetalTextSurface {
  /// 印を出しうるか（表示の構成が印の絵を持ち、並びに印を出せる行がある）。
  var showsTrailingMarks: Bool { presentation.trailingMark != nil && rows.hasTrailingMarks }

  /// 点（view の座標）の下の、印を出せる行と、点が印の上か。本文の区画と行番号の列の上だけ。
  func trailingMarkRow(at point: CGPoint) -> TrailingMarkHover? {
    guard showsTrailingMarks, let mark = presentation.trailingMark,
      let text = currentContent?.text, textView.overview.area(at: point) == nil
    else { return nil }
    let area = surfaceLayout.text
    guard point.x < area.maxX, point.y >= config.topInset else { return nil }
    let offset = Double(config.topInset) - scrollPosition.y
    guard
      let found = rows.trailingMarkSpot(atY: Double(point.y) - offset, lineCount: text.lineCount)
    else { return nil }
    let rect = CGRect(
      x: area.maxX - mark.inset - mark.size.width,
      y: CGFloat(found.top + offset) + (config.lineHeight - mark.size.height) / 2,
      width: mark.size.width, height: mark.size.height)
    return TrailingMarkHover(row: found.row, line: found.line, onMark: rect.contains(point))
  }

  /// ポインタ（view の座標。view の外なら nil）の下の行へ印を移す（変われば材料に書く）。
  func hoverTrailingMark(at point: CGPoint?) {
    let next = point.flatMap { trailingMarkRow(at: $0) }
    guard next != trailingMarkHover else { return }
    trailingMarkHover = next
    publishTrailingMark()
  }

  /// 印の材料を書く（取引の中）。
  func publishTrailingMark() {
    let material: TrailingMarkMaterial? = trailingMarkHover.flatMap { hover in
      guard let mark = presentation.trailingMark, let looks = trailingMarkLooks else { return nil }
      return TrailingMarkMaterial(
        look: hover.onMark ? looks.hovered : looks.normal, row: hover.row, size: mark.size,
        inset: mark.inset)
    }
    write { $0.trailingMark = material }
  }

  /// 印の絵を外観・色空間・倍率で描き直す（表示の構成を置いたとき・外観が変わったとき）。
  func paintTrailingMark() {
    guard let mark = presentation.trailingMark else {
      trailingMarkLooks = nil
      return
    }
    let look = ZonePainter.Look(
      appearance: textView.effectiveAppearance, space: space, scale: scale)
    let paint = { (image: NSImage) in
      let layer = ZoneLayer(elements: [
        .image(ZoneImage(frame: CGRect(origin: .zero, size: mark.size), image: image))
      ])
      return self.painter.paint(
        ZonePicture(height: mark.size.height, layers: [(.zero, layer)]), look, serial: { _ in 0 }
      ).material
    }
    trailingMarkLooks = (paint(mark.image), paint(mark.hoveredImage))
  }

  /// 印が押された。並びの受け手へ知らせる。
  func pressTrailingMark(_ line: TrailingMarkLine) {
    transact { trailingMarkTarget?.surface(self, didPressTrailingMarkOn: line) }
  }
}
