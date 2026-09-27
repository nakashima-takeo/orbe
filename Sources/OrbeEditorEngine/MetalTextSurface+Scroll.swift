import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// スクロール——指の出来事、main の操作（先頭に・中央へ・見えるところへ）、取引の見せ方、スクロールだけのキー。
extension MetalTextSurface {
  /// 指のスクロールの始まりと終わりを IME にも知らせる（候補窓・音声入力の印をスクロールの間は隠し、終わりで置き直す）。
  func scrollWheel(_ event: NSEvent) {
    let context = textView.inputContext
    if event.phase == .began { context?.textInputClientWillStartScrollingOrZooming() }
    scroll(ScrollInput(event))
    if event.phase == .ended || event.phase == .cancelled {
      context?.invalidateCharacterCoordinates()
      context?.textInputClientDidEndScrollingOrZooming()
    }
  }

  /// スクロールの出来事（面自身の入力）をその場で箱の物理へ当て、見えている範囲をその場で知らせ、処理の終わりで出す。
  /// 先に置いてまだ出していない位置と範囲があれば、出来事より前のことなので先に出す。
  func scroll(_ input: ScrollInput) {
    inputScope {
      if pending.position != nil || pending.limits != nil { flush() }
      guard scroll.apply(input) else { return }
      pending.wakes = true
      refreshViewport()
    }
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

  /// 行を見えている高さの中央へ置き、それから列が横に見えるところまで寄せる（横は描画スレッドが行を組んで寄せる）。
  func scrollToCenter(_ offset: Int) {
    transact(reveal: .center, of: NSRange(location: offset, length: 0))
  }

  /// 区間が見えるところまで最小限スクロールする（縦に見えていれば縦は動かず、横に隠れていれば横だけ寄る。横は描画スレッドが
  /// 行を組んで寄せ、動けば見えている範囲を知らせ直す）。
  func scrollToVisible(_ range: NSRange) {
    transact(reveal: .minimal, of: range)
  }

  // MARK: - スクロールだけのキー（キャレットは動かない）

  /// PageUp・PageDown——見えている高さから 1 行を残した量ずつ。
  func scrollPages(_ pages: Int) {
    let visible = scrollState().limits.viewport.y - Double(config.lineHeight)
    scrollBy(Double(pages) * max(Double(config.lineHeight), visible))
  }

  func scrollLines(_ lines: Int) {
    scrollBy(Double(lines) * Double(config.lineHeight))
  }

  /// Home は先頭、End は最後の 1 画面（最終行を下端に）。
  func scrollToDocumentEdge(end: Bool) {
    guard let text = currentContent?.text else { return }
    let bottom =
      Double(text.lineCount) * Double(config.lineHeight) - scrollState().limits.viewport.y
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

  /// 今の位置（取引の中で置いた位置・まだ出していない位置を当てたもの）。
  var scrollPosition: SIMD2<Double> { scrollState().position }

  // MARK: - 位置の計算

  /// 取引の後に置く位置——頼まれた位置から、見せ方に従って区間（無ければ主のキャレット）が見えるところまで。今の位置から
  /// 動かなければ nil。
  func position(after transaction: Transaction, cursors: CursorList, _ text: TextRope)
    -> SIMD2<Double>?
  {
    let now = scroll.peek(at: CACurrentMediaTime(), limits: pending.limits, place: pending.position)
      .position
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
    let height = scrollState().limits.viewport.y
    return SIMD2(p.x, Double(row) * lineHeight + lineHeight / 2 - height / 2)
  }

  /// 区間の行が縦に見えるところまで最小限動かした位置（横は描画スレッドが行を組んで寄せる）。
  private func visible(_ range: NSRange, _ text: TextRope, from start: SIMD2<Double>)
    -> SIMD2<Double>
  {
    let location = min(max(0, range.location), text.length)
    let end = min(max(location, NSMaxRange(range)), text.length)
    let rows = text.rows(of: NSRange(location: location, length: end - location))
    let lineHeight = Double(config.lineHeight)
    let height = scrollState().limits.viewport.y
    var p = start
    let top = Double(rows.lowerBound) * lineHeight
    let bottom = Double(rows.upperBound + 1) * lineHeight
    if top < p.y || bottom - top > height {
      p.y = top
    } else if bottom > p.y + height {
      p.y = bottom - height
    }
    return p
  }

  /// 行の数が `lineCount` のときの範囲の値。見えている大きさは本文の区画から上端の余白を除いたもの。
  func limits(lineCount: Int) -> LimitsUpdate {
    let text = config.layout(size: size, lineCount: lineCount).text
    return LimitsUpdate(
      lineCount: lineCount, lineHeight: Double(config.lineHeight),
      viewport: SIMD2(Double(text.width), Double(max(0, text.height - config.topInset))),
      cell: Double(config.cell))
  }

  /// 今の区画の配置（出す前の写しの行の数で）。
  var surfaceLayout: SurfaceLayout {
    config.layout(size: size, lineCount: currentContent?.text.lineCount ?? 1)
  }

  /// 見えている範囲を出し直し、変わっていれば文書へ知らせる（同期）。変換中なら IME にも知らせる（候補窓が追従する）。
  func refreshViewport() {
    let (position, limits) = scrollState()
    guard let current = measureViewport(position: position, limits: limits), current != viewport
    else { return }
    viewport = current
    delegate?.surfaceDidChangeViewport(self)
    guard editor.isComposing, let context = textView.inputContext else { return }
    context.invalidateCharacterCoordinates()
    if #available(macOS 15.4, *) { context.textInputClientDidScroll() }
  }

  /// 見えている範囲。行は y = 行 × 行高で並び、端を越えて見せている分は端で数える。見えている高さが無ければ nil。
  private func measureViewport(position: SIMD2<Double>, limits: ScrollPhysics.Limits)
    -> TextViewport?
  {
    guard limits.viewport.y > 0, let text = currentContent?.text else { return nil }
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
