import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// スクロール——指の出来事、main の操作（区間を見せる・俯瞰の操作の位置）、取引の見せ方、スクロールだけのキー。
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

  /// スクロールの出来事（面自身の入力）をその場で箱の物理へ当てて描画スレッドを起こし、見えている範囲をその場で知らせ、
  /// それへの反応は処理の終わりで出す。当てた位置は当てた時点で描画スレッドから見えるので、起こすのを処理の終わりまで
  /// 待たない（待つと、main が詰まった後にまとめて届いた出来事の分だけ、起こされたコマが組む行が増える）。先に置いて
  /// まだ出していない位置と範囲があれば、出来事より前のことなので先に出す。
  func scroll(_ input: ScrollInput) {
    inputScope {
      if pending.position != nil || pending.limits != nil { flush() }
      guard scroll.apply(input) else { return }
      wake()
      refreshViewport()
    }
  }

  /// 描画スレッドだけが変える位置と範囲（端への戻り・組んだ行で伸びた横の範囲）が変わった。
  func scrollDidAdvance() {
    refreshViewport()
  }

  /// 先頭に見えている行（小数。行 + 隠れている割合）と見えている行数——俯瞰の式の入力。取引の中で置いた位置も当てた
  /// 今の位置から出す（トラックを押して飛んだ直後の同じ押下の中でも、飛んだ後の値）。端を越えて見せている分は端で数える。
  var viewportLines: (first: CGFloat, visible: CGFloat) {
    let (position, limits) = scrollState()
    guard limits.viewport.y > 0, let text = currentContent?.text else { return (0, 0) }
    let lineHeight = limits.lineHeight
    let y = min(max(0, position.y), limits.maximum.y)
    let row = min(Int((y / lineHeight).rounded(.down)), text.lineCount - 1)
    let hidden = min(max((y - Double(row) * lineHeight) / lineHeight, 0), 1)
    return (CGFloat(Double(row) + hidden), CGFloat(limits.viewport.y / lineHeight))
  }

  /// 先頭行（小数）の位置へ置く（`viewportLines` の逆。行は行の数に収める。横位置は動かさない）。
  func scroll(toFirstLine line: CGFloat) {
    guard let text = currentContent?.text else { return }
    let clamped = min(max(0, line), CGFloat(text.lineCount - 1))
    place(SIMD2(scrollPosition.x, Double(clamped) * Double(config.lineHeight)))
  }

  /// 横の位置を置く（縦は動かさない）。
  func scroll(toX x: CGFloat) {
    place(SIMD2(Double(x), scrollPosition.y))
  }

  /// 区間を方針どおりに見せる。縦の位置は取引の終わりに出す前の位置から決め、横は描画スレッドが区間の行を組んで寄せる
  /// （動けば見えている範囲を知らせ直す）。
  func reveal(_ range: NSRange, policy: TextReveal) {
    transact(reveal: .showing(policy), of: range)
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

  /// 取引の後に置く位置——頼まれた位置から、見せ方に従って区間（無ければ主のキャレット）の行を縦に置いた位置（横は描画
  /// スレッドが行を組んで寄せる）。今の位置から動かなければ nil。
  func position(after transaction: Transaction, cursors: CursorList, _ text: TextRope)
    -> SIMD2<Double>?
  {
    let now = scrollPosition
    var p = transaction.scrollTo ?? now
    let policy: TextReveal
    switch transaction.reveal {
    case .none: return p == now ? nil : p
    case .showing(let shown): policy = shown
    case .page(let lines):
      p.y += Double(lines) * Double(config.lineHeight)
      policy = .minimal
    }
    let caret = NSRange(location: cursors.primary.position, length: 0)
    let range = transaction.revealing ?? caret
    let location = min(max(0, range.location), text.length)
    let end = min(max(location, NSMaxRange(range)), text.length)
    let lineHeight = Double(config.lineHeight)
    let first = policy.firstLine(
      showing: text.rows(of: NSRange(location: location, length: end - location)),
      first: p.y / lineHeight, visible: scrollState().limits.viewport.y / lineHeight)
    p.y = first * lineHeight
    return p == now ? nil : p
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

  /// 見えている範囲を出し直し、変わっていれば文書へ知らせる（同期）。本文が動いていれば、変換中の IME にも知らせる
  /// （候補窓が追従する）。
  func refreshViewport() {
    let (position, limits) = scrollState()
    if let current = measureViewport(position: position, limits: limits), current != viewport {
      viewport = current
      delegate?.surfaceDidChangeViewport(self)
    }
    inputMethodScrollDidChange(position)
  }

  /// 見せている位置（端を越えて見せている分を含む）が前回から動いたら、変換中の IME へ文字の座標が変わったと知らせる。
  /// 見えている範囲の値では足りない——横だけの動き（キャレットへの横の寄せ・横ホイール・横の弾性の戻り）は先頭行も
  /// 行数も変えない。
  private func inputMethodScrollDidChange(_ position: SIMD2<Double>) {
    guard position != inputMethodPosition else { return }
    inputMethodPosition = position
    guard editor.isComposing, let context = textView.inputContext else { return }
    context.invalidateCharacterCoordinates()
    if #available(macOS 15.4, *) { context.textInputClientDidScroll() }
  }

  /// 見えている範囲。行は y = 行 × 行高で並び、端を越えて見せている分は端で数える。見えている高さが無ければ nil。
  private func measureViewport(position: SIMD2<Double>, limits: ScrollPhysics.Limits)
    -> TextViewport?
  {
    guard limits.viewport.y > 0, let text = currentContent?.text else { return nil }
    let y = min(max(0, position.y), limits.maximum.y)
    let row = min(Int((y / limits.lineHeight).rounded(.down)), text.lineCount - 1)
    return TextViewport(
      firstVisible: text.lineStart(row), visibleLines: CGFloat(limits.viewport.y / limits.lineHeight))
  }
}
