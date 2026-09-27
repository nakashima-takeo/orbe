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
    guard let text = currentContent?.text else { return }
    let row = text.row(containing: offset)
    let fraction = Double(min(max(0, hiddenFraction), 1))
    place(SIMD2(scrollPosition.x, (Double(row) + fraction) * Double(config.lineHeight)))
  }

  /// 行を見えている高さの中央へ置き、それから列が横に見えるところまで寄せる。
  func scrollToCenter(_ offset: Int) {
    transact(reveal: .center, of: NSRange(location: offset, length: 0))
  }

  /// 区間が見えるところまで最小限スクロールする（縦に見えていれば縦は動かず、横に隠れていれば横だけ寄る）。
  func scrollToVisible(_ range: NSRange) {
    transact(reveal: .minimal, of: range)
  }

  // MARK: - スクロールだけのキー（キャレットは動かない）

  /// PageUp・PageDown——見えている高さから 1 行を残した量ずつ。
  func scrollPages(_ pages: Int) {
    let visible =
      scroll.peek(at: CACurrentMediaTime()).limits.viewport.y - Double(config.lineHeight)
    scrollBy(Double(pages) * max(Double(config.lineHeight), visible))
  }

  func scrollLines(_ lines: Int) {
    scrollBy(Double(lines) * Double(config.lineHeight))
  }

  /// Home は先頭、End は最後の 1 画面（最終行を下端に）。
  func scrollToDocumentEdge(end: Bool) {
    guard let text = currentContent?.text else { return }
    let bottom =
      Double(text.lineCount) * Double(config.lineHeight)
      - scroll.peek(at: CACurrentMediaTime()).limits.viewport.y
    place(SIMD2(scrollPosition.x, end ? max(0, bottom) : 0))
  }

  private func scrollBy(_ dy: Double) {
    let now = scrollPosition
    place(SIMD2(now.x, now.y + dy))
  }

  /// 位置を置く（アニメーションしない。取引の終わりに置く）。
  func place(_ p: SIMD2<Double>) {
    transact(scrollTo: p)
  }

  /// 今の位置（取引の中で置いた位置があればそれ）。
  var scrollPosition: SIMD2<Double> {
    transaction?.scrollTo ?? scroll.peek(at: CACurrentMediaTime()).position
  }

  // MARK: - 位置の計算

  /// 取引の後に置く位置——頼まれた位置から、見せ方に従って区間（無ければ主のキャレット）が見えるところまで。今の位置から
  /// 動かなければ nil。
  func position(after transaction: Transaction, cursors: CursorList, _ text: TextRope)
    -> SIMD2<Double>?
  {
    let now = scroll.peek(at: CACurrentMediaTime()).position
    var p = transaction.scrollTo ?? now
    if transaction.reveal != .none {
      let caret = NSRange(location: cursors.primary.position, length: 0)
      let range = transaction.revealing ?? caret
      switch transaction.reveal {
      case .none, .minimal: break
      case .center: p = centered(range.location, text, from: p)
      case .page(let lines): p.y += Double(lines) * Double(config.lineHeight)
      }
      p = visible(range, text, from: p)
    }
    return p == now ? nil : p
  }

  /// オフセットの行を見えている高さの中央に置いた位置。
  private func centered(_ offset: Int, _ text: TextRope, from p: SIMD2<Double>) -> SIMD2<Double> {
    let row = text.row(containing: min(max(0, offset), text.length))
    let lineHeight = Double(config.lineHeight)
    let height = scroll.peek(at: CACurrentMediaTime()).limits.viewport.y
    return SIMD2(p.x, Double(row) * lineHeight + lineHeight / 2 - height / 2)
  }

  /// 区間が見えるところまで最小限動かした位置。横の位置は描画と同じ組版の規則で出す。
  private func visible(_ range: NSRange, _ text: TextRope, from start: SIMD2<Double>)
    -> SIMD2<Double>
  {
    let range = NSRange(
      location: min(max(0, range.location), text.length),
      length: min(max(0, range.length), text.length - min(max(0, range.location), text.length)))
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
    let x = { (offset: Int) in Double(stops.carets.x(offset - lineStart)) }
    let x0 = x(range.location)
    let x1 = rows.lowerBound == rows.upperBound ? x(NSMaxRange(range)) : x0
    if x0 < p.x || x1 - x0 > area.x {
      p.x = x0
    } else if x1 > p.x + area.x {
      p.x = x1 - area.x
    }
    return p
  }

  func updateLimits(lineCount: Int, heldUntil revision: Int? = nil) {
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
