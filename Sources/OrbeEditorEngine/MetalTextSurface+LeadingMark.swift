import AppKit
import OrbeEditorCore

/// 行の頭の印を描く材料——ポインタの下の行に出す絵と、引いている範囲（並びの順で最初と最後の行）。線は並びと表示の構成
/// から描画スレッドが描く。
struct LeadingMarkMaterial: Sendable {
  var look: ZoneMaterial?
  var size: CGSize
  var hover: LeadingMarkRow?
  var range: (first: LeadingMarkRow, last: LeadingMarkRow)?
}

/// 引いている範囲——押した行と、最後にポインタの下に在った同じ組の行、押したときの本文の版。
struct LeadingMarkDrag {
  var anchor: LeadingMarkSpot
  var end: LeadingMarkSpot
  var version: Int?

  /// 並びの順で最初と最後の行。
  func ordered(in rows: RowLayout) -> (first: LeadingMarkSpot, last: LeadingMarkSpot) {
    rows.precedes(end.row, anchor.row) ? (end, anchor) : (anchor, end)
  }
}

/// 行の頭の印——表示の構成が印の見え方を持ち、並びが印の組を持つ行に、頭の列の線を描き、ポインタが乗った行に絵を出す。
/// 絵を押せば行を、引けば同じ組の範囲を、離したときに並びの受け手へ知らせる。ポインタの下の行と引いている範囲は材料の
/// 1 欄で、変わったときだけ書く（行も絵の差し込みも描き直さない）。
extension MetalTextSurface {
  /// 印を出しうるか（表示の構成が印の見え方を持ち、並びに印を出せる行がある）。
  var showsLeadingMarks: Bool { presentation.leadingMark != nil && rows.hasLeadingMarks }

  /// 点（view の座標）の行の、印を出せる行。頭の列・行番号の列・本文の区画の上だけ（俯瞰の上は nil）。
  func leadingMarkSpot(at point: CGPoint) -> LeadingMarkSpot? {
    guard showsLeadingMarks, let text = currentContent?.text,
      textView.overview.area(at: point) == nil, point.x < surfaceLayout.text.maxX,
      point.y >= config.topInset
    else { return nil }
    let y = Double(point.y - config.topInset) + scrollPosition.y
    return rows.markSpot(atY: y, lineCount: text.lineCount)
  }

  /// 点（view の座標）が、印を出せる行の頭の列の上なら、その行（印の当たり）。
  func leadingMarkTarget(at point: CGPoint) -> LeadingMarkSpot? {
    guard point.x >= 0, point.x < surfaceLayout.gutter.lead else { return nil }
    return leadingMarkSpot(at: point)
  }

  /// ポインタ（view の座標。view の外なら nil）の下の行へ絵を移す（変われば材料に書く）。印を押している間は絵を出さず、
  /// 引いていればポインタの下の行（上下の端に収めた所）まで範囲を伸ばす（引いている間のホイール）。
  func hoverLeadingMark(at point: CGPoint?) {
    if leadingMarkHeld {
      if leadingMarkDrag != nil, let point { extendLeadingMarkDrag(to: point) }
      return
    }
    let next = point.flatMap { leadingMarkSpot(at: $0) }
    guard next != leadingMarkHover else { return }
    leadingMarkHover = next
    publishLeadingMark()
  }

  /// 印 `spot` を押した（引き始める）。絵を下ろし、押した行だけの範囲にする。
  func beginLeadingMarkDrag(_ spot: LeadingMarkSpot) {
    leadingMarkHeld = true
    leadingMarkHover = nil
    leadingMarkDrag = LeadingMarkDrag(anchor: spot, end: spot, version: currentContent?.version)
    publishLeadingMark()
  }

  /// 引いている範囲を、点（view の座標。上下の端に収める）の下の所まで伸ばす。`position` はスクロールの位置（省けば今の
  /// 位置）。本文が変わっていれば、引く操作を終える。
  func extendLeadingMarkDrag(to point: CGPoint, position: SIMD2<Double>? = nil) {
    guard var drag = leadingMarkDrag, let text = currentContent?.text else { return }
    guard drag.version == currentContent?.version else { return cancelLeadingMarkDrag() }
    let clamped = min(max(point.y, config.topInset), max(config.topInset, size.height - 0.5))
    let y = Double(clamped - config.topInset) + (position ?? scrollPosition).y
    let row = rows.reach(from: drag.anchor, towardY: y, lineCount: text.lineCount)
    guard row != drag.end.row, let end = rows.spot(of: row, lineCount: text.lineCount) else {
      return
    }
    drag.end = end
    leadingMarkDrag = drag
    publishLeadingMark()
  }

  /// 離した。範囲を下ろし、並びの順で最初と最後の行を並びの受け手へ知らせる（同じ取引で、受け手が並びを置き直せる）。
  func finishLeadingMarkDrag() {
    leadingMarkHeld = false
    guard let drag = leadingMarkDrag else { return }
    transact {
      leadingMarkDrag = nil
      publishLeadingMark()
      guard drag.version == currentContent?.version else { return }
      let (first, last) = drag.ordered(in: rows)
      leadingMarkTarget?.surface(self, didMarkFrom: first.line, to: last.line)
    }
  }

  /// 押している間に窓から外れた（離すのが届かない）。引く操作を知らせずに終え、押している姿を下ろす。
  func releaseLeadingMark() {
    leadingMarkHeld = false
    cancelLeadingMarkDrag()
  }

  /// 引く操作を、知らせずに終える（並びを置き直した・本文が変わった）。離すまでは絵を出さない。
  func cancelLeadingMarkDrag() {
    guard leadingMarkDrag != nil else { return }
    leadingMarkDrag = nil
    publishLeadingMark()
  }

  /// 印の材料を書く（取引の中）。
  func publishLeadingMark() {
    let material: LeadingMarkMaterial? = presentation.leadingMark.flatMap { mark in
      guard leadingMarkHover != nil || leadingMarkDrag != nil else { return nil }
      return LeadingMarkMaterial(
        look: leadingMarkLook, size: mark.size, hover: leadingMarkHover?.row,
        range: leadingMarkDrag.map { drag in
          let (first, last) = drag.ordered(in: rows)
          return (first.row, last.row)
        })
    }
    write { $0.leadingMark = material }
  }

  /// 印の絵を外観・色空間・倍率で描き直す（表示の構成を置いたとき・外観が変わったとき）。
  func paintLeadingMark() {
    guard let mark = presentation.leadingMark else {
      leadingMarkLook = nil
      return
    }
    let look = ZonePainter.Look(
      appearance: textView.effectiveAppearance, space: space, scale: scale)
    let layer = ZoneLayer(elements: [
      .image(ZoneImage(frame: CGRect(origin: .zero, size: mark.size), image: mark.image))
    ])
    leadingMarkLook =
      painter.paint(
        ZonePicture(height: mark.size.height, layers: [(.zero, layer)]), look, serial: { _ in 0 }
      ).material
  }
}
