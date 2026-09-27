import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// スクロール——指の出来事、main の操作（先頭に・中央へ・見えるところへ）、取引の見せ方、スクロールだけのキー。
extension MetalTextSurface {
  func scrollWheel(_ event: NSEvent) {
    scroll(ScrollInput(event))
  }

  /// スクロールの出来事を箱に書き、描画スレッドを起こし、見えている範囲をその場で知らせる。
  func scroll(_ input: ScrollInput) {
    guard scroll.apply(input) else { return }
    wake()
    refreshViewport()
  }

  /// 描画スレッドだけが変える位置と範囲（端への戻り・組んだ行で伸びた横の範囲）が変わった。
  func scrollDidAdvance() {
    refreshViewport()
  }

  func scroll(toTop offset: Int, hiddenFraction: CGFloat) {
    guard let text = material.read().content?.text else { return }
    let row = text.row(containing: offset)
    let fraction = Double(min(max(0, hiddenFraction), 1))
    let now = scroll.peek(at: CACurrentMediaTime()).position
    place(SIMD2(now.x, (Double(row) + fraction) * Double(config.lineHeight)))
  }

  /// 行を見えている高さの中央へ置き、それから列が横に見えるところまで寄せる。
  func scrollToCenter(_ offset: Int) {
    guard let text = material.read().content?.text else { return }
    place(centered(offset, text, from: scroll.peek(at: CACurrentMediaTime()).position))
  }

  /// 区間が見えるところまで最小限スクロールする（縦に見えていれば縦は動かず、横に隠れていれば横だけ寄る）。
  func scrollToVisible(_ range: NSRange) {
    guard let text = material.read().content?.text else { return }
    place(visible(range, text, from: scroll.peek(at: CACurrentMediaTime()).position))
  }

  /// 取引の見せ方に従って位置を置く（取引の材料の版を添える）。
  func reveal(_ reveal: Reveal, heldUntil revision: Int) {
    guard reveal != .none, let text = material.read().content?.text else { return }
    let caret = editor.state.cursors.primary.position
    var p = scroll.peek(at: CACurrentMediaTime()).position
    switch reveal {
    case .none: return
    case .minimal: break
    case .center: p = centered(caret, text, from: p)
    case .page(let lines): p.y += Double(lines) * Double(config.lineHeight)
    }
    p = visible(NSRange(location: caret, length: 0), text, from: p)
    scroll.place(p, heldUntil: revision)
  }

  // MARK: - スクロールだけのキー（キャレットは動かない）

  /// PageUp・PageDown——見えている高さから 1 行を残した量ずつ。
  func scrollPages(_ pages: Int) {
    let visible = scroll.peek(at: CACurrentMediaTime()).limits.viewport.y - Double(config.lineHeight)
    scrollBy(Double(pages) * max(Double(config.lineHeight), visible))
  }

  func scrollLines(_ lines: Int) {
    scrollBy(Double(lines) * Double(config.lineHeight))
  }

  /// Home は先頭、End は最後の 1 画面（最終行を下端に）。
  func scrollToDocumentEdge(end: Bool) {
    guard let text = material.read().content?.text else { return }
    let now = scroll.peek(at: CACurrentMediaTime()).position
    let bottom =
      Double(text.lineCount) * Double(config.lineHeight)
      - scroll.peek(at: CACurrentMediaTime()).limits.viewport.y
    place(SIMD2(now.x, end ? max(0, bottom) : 0))
  }

  private func scrollBy(_ dy: Double) {
    let now = scroll.peek(at: CACurrentMediaTime()).position
    place(SIMD2(now.x, now.y + dy))
  }

  // MARK: - 位置の計算

  /// オフセットの行を見えている高さの中央に置き、列が横に見えるところまで寄せた位置。
  private func centered(_ offset: Int, _ text: TextRope, from p: SIMD2<Double>) -> SIMD2<Double> {
    let location = min(max(0, offset), text.length)
    let row = text.row(containing: location)
    let lineHeight = Double(config.lineHeight)
    let height = scroll.peek(at: CACurrentMediaTime()).limits.viewport.y
    let centered = SIMD2(p.x, Double(row) * lineHeight + lineHeight / 2 - height / 2)
    return visible(NSRange(location: location, length: 0), text, from: centered)
  }

  /// 区間が見えるところまで最小限動かした位置。横の位置は描画と同じ組版の規則で出す。
  private func visible(_ range: NSRange, _ text: TextRope, from start: SIMD2<Double>)
    -> SIMD2<Double>
  {
    let rows = text.rows(of: range)
    let lineHeight = Double(config.lineHeight)
    let area = scroll.peek(at: CACurrentMediaTime()).limits.viewport
    var p = start
    let top = Double(rows.lowerBound) * lineHeight
    let bottom = Double(rows.upperBound + 1) * lineHeight
    if top < p.y || bottom - top > area.y {
      p.y = top
    } else if bottom > p.y + area.y {
      p.y = bottom - area.y
    }
    let (source, lineStart) = LineShaper.source(row: rows.lowerBound, in: text)
    let stops = lineStops.stops(source, tabWidth: config.tabWidth(columns: indentation.unit))
    scroll.noteLine(width: Double(stops.width))
    let x = { (offset: Int) in
      Double(CaretX.x(ofColumn: offset - lineStart, offsets: stops.offsets, xs: stops.xs, width: stops.width))
    }
    let x0 = x(range.location)
    let x1 = rows.lowerBound == rows.upperBound ? x(NSMaxRange(range)) : x0
    if x0 < p.x || x1 - x0 > area.x {
      p.x = x0
    } else if x1 > p.x + area.x {
      p.x = x1 - area.x
    }
    return p
  }

  /// その場で位置を置く（アニメーションしない）。
  func place(_ p: SIMD2<Double>) {
    scroll.place(p)
    wake()
    refreshViewport()
  }

  func updateLimits(heldUntil revision: Int? = nil) {
    let lineCount = material.read().content?.text.lineCount ?? 1
    let viewport = SIMD2(
      Double(size.width - config.columnWidth(lineCount: lineCount)),
      Double(size.height - config.topInset))
    let lineHeight = Double(config.lineHeight)
    let cell = Double(config.cell)
    scroll.updateLimits(heldUntil: revision) {
      $0.lineCount = lineCount
      $0.lineHeight = lineHeight
      $0.viewport = viewport
      $0.cell = cell
    }
  }

  /// 見えている範囲を出し直し、変わっていれば文書へ知らせる（同期）。
  func refreshViewport() {
    let (position, limits) = scroll.peek(at: CACurrentMediaTime())
    guard let current = measureViewport(position: position, limits: limits), current != viewport
    else { return }
    viewport = current
    delegate?.surfaceDidChangeViewport(self)
  }

  /// 見えている範囲。行は y = 行 × 行高で並び、端を越えて見せている分は端で数える。見えている高さが無ければ nil。
  private func measureViewport(position: SIMD2<Double>, limits: ScrollPhysics.Limits)
    -> TextViewport?
  {
    guard limits.viewport.y > 0, let text = material.read().content?.text else { return nil }
    let lineHeight = limits.lineHeight
    let maximum = limits.maximum
    let x = min(max(0, position.x), maximum.x)
    let y = min(max(0, position.y), maximum.y)
    let row = min(Int((y / lineHeight).rounded(.down)), text.lineCount - 1)
    let hidden = min(max((y - Double(row) * lineHeight) / lineHeight, 0), 1)
    let cell = Double(config.cell)
    return TextViewport(
      firstVisible: text.lineStart(row), hiddenFraction: CGFloat(hidden),
      visibleLines: CGFloat(limits.viewport.y / lineHeight),
      clipsRight: x < maximum.x - 0.5 / Double(textView.window?.backingScaleFactor ?? 2),
      hiddenColumns: CGFloat(x / cell), visibleColumns: CGFloat(max(0, limits.viewport.x) / cell))
  }
}
