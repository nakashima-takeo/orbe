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

  /// 描画スレッドだけが変える位置と範囲（端への戻り・組んだ行で伸びた横の範囲・入力欄の横の送り）が変わった。入力欄で
  /// 変換していれば、候補窓を新しい送りに付いてこさせる。
  func scrollDidAdvance() {
    refreshViewport()
    if let site = primarySite, !site.isBody, site.editor.isComposing {
      site.inputMethodCoordinatesDidChange()
    }
  }

  /// 先頭に見えている所と見えている高さ（表示の単位。差し込みが無ければ行 + 隠れている割合と行数）——俯瞰の式の入力。
  /// 取引の中で置いた位置も当てた今の位置から出す（トラックを押して飛んだ直後の同じ押下の中でも、飛んだ後の値）。端を
  /// 越えて見せている分は端で数える。
  var viewportLines: (first: CGFloat, visible: CGFloat) {
    let (position, limits) = scrollState()
    guard limits.viewport.y > 0, let text = currentContent?.text else { return (0, 0) }
    return limits.viewportLines(at: position, rows: rows, lineCount: text.lineCount)
  }

  /// 先頭（表示の単位）の位置へ置く（`viewportLines` の逆。最後の項目の上端までに収める。横位置は動かさない）。
  func scroll(toFirstLine line: CGFloat) {
    guard let text = currentContent?.text else { return }
    let clamped = min(max(0, Double(line)), rows.lastUnit(lineCount: text.lineCount))
    place(SIMD2(scrollPosition.x, clamped * Double(config.lineHeight)))
  }

  /// 横の位置を置く（縦は動かさない）。
  func scroll(toX x: CGFloat) {
    place(SIMD2(Double(x), scrollPosition.y))
  }

  /// 区間を方針どおりに見せる。縦の位置は取引の終わりに出す前の位置から決め、横は描画スレッドが区間の行を組んで寄せる
  /// （動けば見えている範囲を知らせ直す）。
  func reveal(_ range: NSRange, policy: TextReveal) {
    bodySite.transact(reveal: .showing(policy), of: range)
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

  /// Home は先頭、End は最後の 1 画面（最後の項目を下端に）。
  func scrollToDocumentEdge(end: Bool) {
    guard let text = currentContent?.text else { return }
    let bottom = rows.totalHeight(lineCount: text.lineCount) - scrollState().limits.viewport.y
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

  /// 取引の後に置く位置——頼まれた位置から、見せ方に従って縦の範囲 `span`（見せ方を頼んだ場が出した、区間の行の縦の
  /// 範囲。表示の単位）を縦に置いた位置（本文の横は描画スレッドが行を組んで寄せる）。ページ送りの量は本文の場だけが
  /// 送る。今の位置から動かなければ nil。
  func position(after transaction: Transaction, span: Range<Double>?) -> SIMD2<Double>? {
    let now = scrollPosition
    var p = transaction.scrollTo ?? now
    let lineHeight = Double(config.lineHeight)
    let policy: TextReveal
    switch transaction.reveal {
    case .none: return p == now ? nil : p
    case .showing(let shown): policy = shown
    case .page(let lines):
      if transaction.revealSite?.isBody != false { p.y += Double(lines) * lineHeight }
      policy = .minimal
    }
    guard let span else { return p == now ? nil : p }
    let current = p.y / lineHeight
    let first = policy.firstLine(
      showing: span, first: current, visible: scrollState().limits.viewport.y / lineHeight)
    // 方針が動かさないときは今の先頭をそのまま返すので、置き直さない（行高との往復で 1ulp ずれた位置を置くと、端を越えて
    // 見せている間の位置が端へ収められる）。
    if first != current { p.y = first * lineHeight }
    return p == now ? nil : p
  }

  /// 行の数が `lineCount` のときの範囲の値（縦の端は今の縦の並びの最後の項目）。見えている大きさは本文の区画から上端の
  /// 余白を除いたもの。
  func limits(lineCount: Int) -> LimitsUpdate {
    let text = config.layout(
      size: size, lineCount: lineCount, showsMinimap: presentation.showsMinimap
    ).text
    return LimitsUpdate(
      lastTop: rows.lastTop(lineCount: lineCount), lineHeight: Double(config.lineHeight),
      viewport: SIMD2(Double(text.width), Double(max(0, text.height - config.topInset))),
      cell: Double(config.cell))
  }

  /// 今の区画の配置（出す前の写しの行の数で）。
  var surfaceLayout: SurfaceLayout {
    config.layout(
      size: size, lineCount: currentContent?.text.lineCount ?? 1,
      showsMinimap: presentation.showsMinimap)
  }

  /// 見えている範囲を出し直し、変わっていれば文書へ知らせる（同期）。本文が動いていれば、変換中の IME にも知らせる
  /// （候補窓が追従する）。区画の押せる場所がポインタの下を動いたかもしれないので、ホバーとポインタの形も引き直す。
  func refreshViewport() {
    let (position, limits) = scrollState()
    if let current = measureViewport(position: position, limits: limits), current != viewport {
      viewport = current
      delegate?.surfaceDidChangeViewport(self)
    }
    inputMethodScrollDidChange(position)
    refreshPointer()
  }

  /// 見せている位置（端を越えて見せている分を含む）が前回から動いたら、変換中の IME へ文字の座標が変わったと知らせる。
  /// 見えている範囲の値では足りない——横だけの動き（キャレットへの横の寄せ・横ホイール・横の弾性の戻り）は先頭行も
  /// 行数も変えない。
  private func inputMethodScrollDidChange(_ position: SIMD2<Double>) {
    guard position != inputMethodPosition else { return }
    inputMethodPosition = position
    guard primarySite?.editor.isComposing == true, let context = textView.inputContext else {
      return
    }
    context.invalidateCharacterCoordinates()
    if #available(macOS 15.4, *) { context.textInputClientDidScroll() }
  }

  /// 見えている範囲。先頭は縦の並びで先頭に見えている文書の行（塊の上なら次の文書の行）で、端を越えて見せている分は端で
  /// 数える。見えている高さが無ければ nil。
  private func measureViewport(position: SIMD2<Double>, limits: ScrollPhysics.Limits)
    -> TextViewport?
  {
    guard limits.viewport.y > 0, let text = currentContent?.text else { return nil }
    let row = rows.firstVisibleLine(atY: limits.clampedY(position), lineCount: text.lineCount)
    return TextViewport(
      firstVisible: text.lineStart(row),
      visibleLines: CGFloat(limits.viewport.y / limits.lineHeight))
  }
}
