import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// 本文のドラッグ＆ドロップ（AppKit のドラッグ）。同じ面の中は移動（⌥ でコピー）、他の文書・他のアプリへはコピーで
/// 出し、他のアプリの文字も受ける。Finder のファイルは載せる側へ「開く」を渡し、⇧ を押していればパスを入れる。落とす
/// 位置の印は描く材料に置き、本文の上下の端の 1 行の帯の中では自動でスクロールする。絵の差し込みの入力欄へ落とせば
/// 入力欄に入れる（コピー。入力欄が主になる）。絵の差し込みの入力欄でない所（文・押せる場所・ほかに当たらない所）へは
/// 落とせない。
extension MetalTextView: NSDraggingSource {
  /// 読むだけの本文からは写すだけ（運んだ字を消さない）。
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .withinApplication && surface?.bodySite.isEditable != false ? [.move, .copy] : .copy
  }

  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    draggedRange = nil
  }

  /// 選択の文字のドラッグを始める（選択の上を押して動かした）。像は選択の見えている行の文字。
  func beginTextDrag(with event: NSEvent) {
    guard let surface, let text = surface.currentContent?.text else { return }
    let selection = surface.bodySite.editor.state.cursors.primary.selection
    guard selection.length > 0 else { return }
    draggedRange = selection
    let item = NSDraggingItem(pasteboardWriter: text.substring(selection) as NSString)
    let (frame, image) = dragImage(selection, text)
    item.setDraggingFrame(frame, contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  /// 選択の見えている行の文字を、本文と同じ位置に描いた像と、その矩形（view の座標）。本文と同じ行の組版で組んだ行（折り
  /// 返した行は段）から、選択の中の字を描き、矩形はその行の、選択の地と同じ見た目の区間を囲む（右から左の字が混ざる行でも、
  /// 選んだ字が矩形の中に入る）。行の中に選んだ字が無ければ、選択の端に幅 1 の矩形を置く。
  private func dragImage(_ selection: NSRange, _ text: TextRope) -> (NSRect, NSImage) {
    guard let surface else { return (.zero, NSImage()) }
    let config = surface.config
    let p = surface.scrollPosition
    let layout = surface.rows
    let top = max(0, layout.line(atY: p.y))
    let bottom = layout.line(atY: p.y + Double(bounds.height))
    let rows = text.rows(of: selection).clamped(to: top...max(top, bottom))
    let pieces = rows.flatMap { dragPieces(selection, row: $0, text, surface) }
    let frame = pieces.reduce(NSRect.null) { $0.union($1.rect) }
    guard !frame.isNull else { return (.zero, NSImage()) }
    let color = surface.textColor.cgColor
    let image = NSImage(size: frame.size, flipped: true) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.setFillColor(color)
      context.textMatrix = .identity
      for piece in pieces {
        context.saveGState()
        context.translateBy(
          x: piece.origin.x - frame.minX, y: piece.origin.y - frame.minY + config.baseline)
        context.scaleBy(x: 1, y: -1)
        for run in piece.runs {
          let positions = zip(run.xs, run.ys).map { CGPoint(x: $0, y: $1) }
          CTFontDrawGlyphs(run.font, run.glyphs, positions, run.glyphs.count, context)
        }
        context.restoreGState()
      }
      return true
    }
    return (frame, image)
  }

  /// 像の切れ端——選択の中の字と、段の左上と、選択の地と同じ見た目の区間を囲む矩形。
  private struct DragPiece {
    let runs: [ShapedLine.Run]
    let origin: CGPoint
    let rect: NSRect
  }

  /// 行 `row` の、見えている段ごとの像の切れ端。
  private func dragPieces(
    _ selection: NSRange, row: Int, _ text: TextRope, _ surface: MetalTextSurface
  ) -> [DragPiece] {
    let config = surface.config
    let p = surface.scrollPosition
    let layout = surface.rows
    let (source, start) = LineShaper.source(row: row, in: text)
    let lineFrom = max(selection.location, start) - start
    let lineTo = min(NSMaxRange(selection), NSMaxRange(text.contentRange(ofRow: row))) - start
    let shown = LineShaper.display(source)
    let wrap = layout.wrap(ofLine: row)
    let first = wrap?.segment(containing: lineFrom) ?? 0
    let last = wrap?.segment(containing: lineTo, upstream: lineTo > lineFrom) ?? 0
    return (first...max(first, last)).compactMap { segment in
      let top = layout.y(ofSegment: segment, line: row) - p.y
      guard top + Double(config.lineHeight) > 0, top < Double(bounds.height) else { return nil }
      let base = wrap?.start(of: segment) ?? 0
      let end = segment < (wrap?.segments ?? 1) - 1 ? wrap?.start(of: segment + 1) : nil
      let from = max(lineFrom, base) - base
      let to = min(lineTo, end ?? lineTo) - base
      let origin = CGPoint(
        x: surface.surfaceLayout.column - CGFloat(p.x)
          + (segment > 0 ? CGFloat(wrap?.indent ?? 0) : 0),
        y: config.topInset + CGFloat(top))
      let shaped = LineShaper.shape(
        shown.segment(base..<(end ?? shown.units.count), last: end == nil), font: config.font,
        tabWidth: surface.bodySite.tabWidth)
      let carets = shaped.carets
      let segments = carets.segments(from: from, to: to)
      let x0 = segments.first?.lowerBound ?? carets.x(from)
      let x1 = segments.last?.upperBound ?? x0
      return DragPiece(
        runs: shaped.runs.map { $0.selecting(from..<max(from, to)) }, origin: origin,
        rect: NSRect(
          origin: CGPoint(x: origin.x + x0, y: origin.y),
          size: CGSize(width: max(1, x1 - x0), height: config.lineHeight)))
    }
  }

  // MARK: - 受ける

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingEntered(sender, now: CACurrentMediaTime())
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingUpdated(sender, now: CACurrentMediaTime())
  }

  func draggingEntered(_ sender: NSDraggingInfo, now: CFTimeInterval) -> NSDragOperation {
    dropScrollTime = nil
    return draggingUpdated(sender, now: now)
  }

  /// 時刻 `now` に届いた出来事として、落とす位置の印を置き、端の帯の中なら自動でスクロールする（AppKit が周期で呼ぶ
  /// `draggingUpdated(_:)` が、今の時刻で呼ぶ）。スクロールと印は 1 つの取引で置き、当たりは取引の中で置いた位置で取る。
  /// 右列（ミニマップと縦スクロールバー）の上は本文の外として扱い、送らず、戻ったとき上にいた時間ぶん跳ばない。本文に重なる
  /// 横スクロールバーの上は、落とさないが帯の中なら送る。
  func draggingUpdated(_ sender: NSDraggingInfo, now: CFTimeInterval) -> NSDragOperation {
    guard let surface else { return [] }
    var operation: NSDragOperation = []
    surface.input {
      let point = convert(sender.draggingLocation, from: nil)
      let area = overview.area(at: point)
      if area == .minimap || area == .vertical {
        dropScrollTime = nil
      } else {
        autoscrollDrop(at: point, now: now)
      }
      guard area == nil else { return showDrop(nil) }
      switch surface.target(at: point) {
      case .body:
        let drop = dropPlan(sender, site: surface.bodySite)
        showDrop(drop.indicator)
        operation = drop.operation
      case .field(let site):
        showDrop(nil)
        operation = dropPlan(sender, site: site).operation
      case .button, .zoneText, .zoneSpace, .leadingMark:
        showDrop(nil)
      }
    }
    return operation
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    surface?.inputScope { showDrop(nil) }
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    surface?.inputScope { showDrop(nil) }
  }

  /// 落とす。ファイルを開くのは別の文書へ焦点を移すので、印を消してから載せる側へ渡す。
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let surface else { return false }
    var performed = false
    surface.inputScope { performed = performDrop(sender) }
    return performed
  }

  private func performDrop(_ sender: NSDraggingInfo) -> Bool {
    let point = convert(sender.draggingLocation, from: nil)
    guard let surface, overview.area(at: point) == nil else {
      showDrop(nil)
      return false
    }
    let site: EditingSite
    switch surface.target(at: point) {
    case .body: site = surface.bodySite
    case .field(let field): site = field
    case .button, .zoneText, .zoneSpace, .leadingMark:
      showDrop(nil)
      return false
    }
    guard let action = dropPlan(sender, site: site).action else {
      showDrop(nil)
      return false
    }
    switch action {
    case .open(let urls):
      showDrop(nil)
      surface.host?.openFiles(urls)
    case .insertPaths(let urls, let offset):
      guard let host = surface.host else { return false }
      insertDrop(host.insertionText(forFiles: urls), at: offset, moving: nil, into: site)
    case .insert(let string, let offset, let moving):
      insertDrop(string, at: offset, moving: moving, into: site)
    }
    return true
  }

  /// 印を消す・焦点を取る・落とした場を主にする・入れるを 1 つの取引で行う。
  private func insertDrop(
    _ string: String, at offset: Int, moving: NSRange?, into site: EditingSite
  ) {
    guard let surface else { return }
    surface.input {
      showDrop(nil)
      window?.makeFirstResponder(self)
      surface.setPrimary(site.field.map { .field($0.id) } ?? .body)
      site.editor.perform(.drop(string, at: offset, moving: moving))
    }
  }

  /// 板と修飾と当たりを読んで、場 `site` へ落とすときの判断（`DropRules`）に渡す。運んでいる範囲は、本文の場へ落とす
  /// ときだけ見る（入力欄へは写す）。ファイルは本文の場だけが受ける（入力欄は文字だけ受ける）。
  private func dropPlan(_ info: NSDraggingInfo, site: EditingSite) -> DropPlan {
    guard let surface else { return DropPlan() }
    let point = convert(info.draggingLocation, from: nil)
    let board = info.draggingPasteboard
    let own = (info.draggingSource as? MetalTextView) === self && site.isBody
    return DropRules.plan(
      DropSituation(
        offset: site.hit(point, position: surface.scrollPosition)?.offset,
        files: fileURLs(on: board), string: board.string(forType: .string),
        dragged: own ? draggedRange : nil,
        copying: !info.draggingSourceOperationMask.contains(.move),
        shift: NSEvent.modifierFlags.contains(.shift),
        opensFiles: site.isBody && surface.host != nil, inserts: site.isEditable))
  }

  private func showDrop(_ offset: Int?) {
    guard let surface, shownDrop != offset else { return }
    shownDrop = offset
    surface.write { $0.drop = offset }
  }

  /// 本文の上下の端から 1 行の帯の中にいる間、前の刻みから `now` までの経過時間ぶん、選択のドラッグと同じ速さの式で
  /// スクロールする。
  private func autoscrollDrop(at point: CGPoint, now: CFTimeInterval) {
    guard let surface else { return }
    defer { dropScrollTime = now }
    let config = surface.config
    let band = config.lineHeight
    let depth: CGFloat
    if point.y < config.topInset + band {
      depth = -(config.topInset + band - point.y)
    } else if point.y > bounds.height - band {
      depth = point.y - (bounds.height - band)
    } else {
      return
    }
    guard let last = dropScrollTime else { return }
    let (position, limits) = surface.scrollState(at: now)
    let visible = (bounds.height - config.topInset) / band
    let speed = DragScrollSpeed.speed(outside: min(abs(depth), band) / band, visible: visible)
    var p = position
    p.y += Double((depth < 0 ? -speed : speed) * CGFloat(now - last) * band)
    surface.place(simd_clamp(p, .zero, simd_max(limits.maximum, .zero)))
  }
}

extension ShapedLine.Run {
  /// 元の行の区間 `range` の字のグリフだけを残した run。
  fileprivate func selecting(_ range: Range<Int>) -> ShapedLine.Run {
    let kept = offsets.indices.filter { range.contains(offsets[$0]) }
    return ShapedLine.Run(
      font: font, glyphs: kept.map { glyphs[$0] }, xs: kept.map { xs[$0] },
      ys: kept.map { ys[$0] }, offsets: kept.map { offsets[$0] })
  }
}
