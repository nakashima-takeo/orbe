import AppKit
import OrbeEditorCore
import simd

/// 編集の場の幾何（view の座標、pt）と見せ方——点 ↔ 位置、範囲の矩形、キャレットの矩形、見せる縦の範囲。本文の場は面の
/// 縦の並びと横の送りで、入力欄の場は区画の中の矩形と並びの y と場の横の送りで答える。
extension EditingSite {
  /// 文の字体と行の高さ、行の上端から基線まで。
  var font: NSFont { field?.style.font ?? surface.config.font as NSFont }
  var lineHeight: CGFloat { field?.style.lineHeight ?? surface.config.lineHeight }
  var baseline: CGFloat {
    guard let field else { return surface.config.baseline }
    let font = field.style.font
    return (field.style.lineHeight - (font.ascender - font.descender)) / 2 + font.ascender
  }

  /// 入力欄の 1 行目の左上（行頭の x。横の送りを引いた位置。縦の位置 `position` で）。区画が並びに無ければ nil。
  func fieldOrigin(position: SIMD2<Double>? = nil) -> CGPoint? {
    guard let zone, let block = surface.rows.block(ofZone: zone) else { return nil }
    let p = position ?? surface.scrollPosition
    let area = surface.surfaceLayout.text
    return CGPoint(
      x: area.minX + frame.minX - CGFloat(scrollX),
      y: surface.config.topInset + CGFloat(surface.rows.top(ofBlock: block) - p.y) + frame.minY)
  }

  /// 点の場所と、いちばん近い書記素の境（→ `MetalTextSurface.hit`）。入力欄では行を入力欄の行に収める。
  func hit(_ point: CGPoint, position: SIMD2<Double>? = nil) -> PointerHit? {
    guard let field else { return surface.hit(point, position: position) }
    guard let origin = fieldOrigin(position: position), let env = editingEnvironment() else {
      return nil
    }
    let text = env.text
    let line = Int(((point.y - origin.y) / field.style.lineHeight).rounded(.down))
    let row = min(max(0, line), text.lineCount - 1)
    return PointerHit(
      area: .text, row: row,
      offset: text.lineStart(row) + env.geometry.column(atX: point.x - origin.x, row: row))
  }

  /// 点を含む書記素（→ `MetalTextSurface.character(at:)`）。入力欄では入力欄の矩形の中の字だけ。
  func character(at point: CGPoint, position: SIMD2<Double>? = nil) -> NSRange? {
    guard let field else { return surface.character(at: point, position: position) }
    guard let origin = fieldOrigin(position: position), let text = currentContent?.text,
      textArea.contains(point)
    else { return nil }
    let row = Int(((point.y - origin.y) / field.style.lineHeight).rounded(.down))
    guard (0..<text.lineCount).contains(row) else { return nil }
    let (source, start) = LineShaper.source(row: row, in: text)
    let stops = lineStops.stops(source, tabWidth: tabWidth)
    let x = point.x - origin.x
    guard x < stops.width, let glyph = stops.glyph(atX: x) else { return nil }
    return text.grapheme(containing: start + stops.offsets[glyph])
  }

  /// 文の見えている区画（本文は上端の余白の下、入力欄は入力欄の矩形——どちらも本文の区画に収める）。
  var textArea: NSRect {
    let area = surface.surfaceLayout.text
    let top = surface.config.topInset
    let visible = NSRect(x: area.minX, y: top, width: area.width, height: max(0, area.height - top))
    guard !isBody else { return visible }
    guard let origin = fieldOrigin() else { return .zero }
    let rect = NSRect(
      x: origin.x + CGFloat(scrollX), y: origin.y, width: frame.width, height: frame.height)
    return rect.intersection(visible)
  }

  /// 見えている行の範囲（文の行）。入力欄はどの行も見えている。
  var visibleRows: ClosedRange<Int> {
    guard isBody else { return 0...max(0, (currentContent?.text.lineCount ?? 1) - 1) }
    let y = surface.scrollPosition.y
    let top = surface.rows.line(atY: y)
    let bottom = surface.rows.line(atY: y + Double(surface.size.height))
    return top...max(top, bottom)
  }

  /// 1 行の中の範囲の矩形（行の高さいっぱい）。未確定の行の未確定の中の端は `marked` で出す。
  func textRect(
    _ range: NSRange, row: Int, _ env: EditingEnvironment, marked: MarkedLineGeometry?
  ) -> NSRect {
    let start = env.text.lineStart(row)
    let onMarked = marked?.row == row ? marked : nil
    let x0 =
      onMarked?.x(of: range.location) ?? env.geometry.x(ofColumn: range.location - start, row: row)
    let x1 =
      onMarked?.x(of: NSMaxRange(range))
      ?? env.geometry.x(ofColumn: NSMaxRange(range) - start, row: row)
    guard isBody else {
      let origin = fieldOrigin() ?? .zero
      return NSRect(
        x: origin.x + x0, y: origin.y + CGFloat(row) * lineHeight, width: x1 - x0,
        height: lineHeight)
    }
    let p = surface.scrollPosition
    let config = surface.config
    return NSRect(
      x: config.columnWidth(lineCount: env.text.lineCount) + x0 - CGFloat(p.x),
      y: config.topInset + CGFloat(surface.rows.y(ofLine: row) - p.y), width: x1 - x0,
      height: config.lineHeight)
  }

  /// 変換中の未確定の横位置（変換中でなければ nil）。
  var markedLine: MarkedLineGeometry? {
    guard let composition = editor.composition, let text = currentContent?.text else { return nil }
    return MarkedLineGeometry(composition, text: text, cache: lineStops, tabWidth: tabWidth)
  }

  /// 点を含む未確定の字の位置（点が未確定の字の上でなければ nil）。
  func markedCharacter(at point: CGPoint) -> Int? {
    guard let marked = markedLine, let text = currentContent?.text, row(at: point) == marked.row,
      let offset = marked.offset(containingX: lineX(of: point))
    else { return nil }
    return text.grapheme(containing: offset).location
  }

  /// 点のある文の行（文の行の上でなければ nil）。
  private func row(at point: CGPoint) -> Int? {
    guard isBody else {
      guard let origin = fieldOrigin() else { return nil }
      return Int(((point.y - origin.y) / lineHeight).rounded(.down))
    }
    let config = surface.config
    guard point.y >= config.topInset,
      point.x >= config.columnWidth(lineCount: currentContent?.text.lineCount ?? 1),
      case .line(let row) = surface.rows.item(
        atY: Double(point.y - config.topInset) + surface.scrollPosition.y)
    else { return nil }
    return row
  }

  /// 行頭からの点の x。
  func lineX(of point: CGPoint) -> CGFloat {
    guard isBody else { return point.x - (fieldOrigin()?.x ?? 0) }
    let lineCount = currentContent?.text.lineCount ?? 1
    return point.x - surface.config.columnWidth(lineCount: lineCount)
      + CGFloat(surface.scrollPosition.x)
  }

  // MARK: - 見せ方

  /// 区間 `range`（nil なら主のキャレット）の行の縦の範囲（表示の単位——面の行高を 1 とする縦の並びの位置）。
  func revealSpan(_ range: NSRange?) -> Range<Double>? {
    guard let text = currentContent?.text else { return nil }
    let caret = NSRange(location: editor.state.cursors.primary.position, length: 0)
    let shown = range ?? caret
    let location = min(max(0, shown.location), text.length)
    let end = min(max(location, NSMaxRange(shown)), text.length)
    let lines = text.rows(of: NSRange(location: location, length: end - location))
    let rows = surface.rows
    guard let field else {
      return rows.unit(ofLine: lines.lowerBound)..<(rows.unit(ofLine: lines.upperBound) + 1)
    }
    guard let zone, let block = rows.block(ofZone: zone) else { return nil }
    let unit = Double(surface.config.lineHeight)
    let top = rows.top(ofBlock: block) + Double(frame.minY)
    let lineHeight = Double(field.style.lineHeight)
    return (top + Double(lines.lowerBound) * lineHeight)
      / unit..<(top + Double(lines.upperBound + 1) * lineHeight) / unit
  }

  /// 入力欄の横の送りを、主のキャレットが入力欄の幅に見えるところまで最小限動かす（入力欄の場だけ）。
  func revealCaretHorizontally() {
    guard field != nil, let env = editingEnvironment() else { return }
    let text = env.text
    let caret = editor.state.cursors.primary.position
    let row = text.row(containing: caret)
    let x = Double(env.geometry.x(ofColumn: caret - text.lineStart(row), row: row))
    let width = Double(frame.width)
    let caretWidth = Double(surface.config.caretSize.width)
    if x < scrollX {
      scrollX = x
    } else if x + caretWidth > scrollX + width {
      scrollX = max(0, x + caretWidth - width)
    }
  }

}
