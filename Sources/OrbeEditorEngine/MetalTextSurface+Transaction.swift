import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// 面の取引——1 回の操作で箱へ置くものを、取引の終わりに 1 回の書き込みで確定する。描画スレッドは刻みごとに箱を読むので、
/// 操作の途中で何度も書くと「新しい本文に古いキャレット」「スクロールだけ先に動いた」コマが出る。
struct Transaction {
  /// 取引の中で引いた文書の写し（引かなければ nil）。
  var content: SurfaceContent?
  /// 取引の中で届いた行の印。
  var marks: LineMarkSpans?
  /// 取引の中で渡した編集で、組版の変わった行（当てた順）。描画スレッドは変わった行だけを組み直す。
  var rowEdits: [RowEdit] = []
  var reveal: Reveal
  /// 見せ方の前に置くスクロールの位置（ドラッグの自動スクロール）。
  var scrollTo: SIMD2<Double>?
  /// 最も長い行を測り直す（丸ごと置き換え）。
  var remeasure: Bool
  /// 取引の前の主の選択とカーソルの列。
  let selection: NSRange
  let cursors: CursorList
  /// 本文を変えたか。
  var edited = false
}

extension MetalTextSurface {
  /// 今の写しの長さ。
  var textLength: Int? { transaction?.content?.text.length ?? material.read().content?.text.length }

  /// 編集の規則が読む環境。
  func editingEnvironment() -> EditingEnvironment? {
    guard let text = transaction?.content?.text ?? material.read().content?.text else { return nil }
    let lines = Int((Double(size.height - config.topInset) / Double(config.lineHeight)).rounded(.down))
    return EditingEnvironment(
      text: text,
      geometry: ShapedLineGeometry(
        text: text, cache: lineStops, tabWidth: config.tabWidth(columns: indentation.unit)),
      pageLines: max(1, lines - 2), indentation: indentation, killBuffer: KillBuffer.contents)
  }

  /// 1 回の操作を 1 つの取引にする。`body` の間に文書から届く知らせ（行の印・役割の変化）は控えるだけにし、終わりに写し・
  /// 行の印・カーソル・点滅の起点・打鍵の時刻を 1 回の書き込みで描く材料の箱へ置き、見せ方に従った位置を同じ版でスクロール
  /// の箱へ置き、描画スレッドを起こし、選択と見えている範囲を知らせる。
  func transact(reveal: Reveal, remeasure: Bool = false, _ body: () -> Void) {
    guard transaction == nil else {
      body()
      if reveal != .none { transaction?.reveal = reveal }
      return
    }
    transaction = Transaction(
      content: nil, marks: nil, reveal: reveal, remeasure: remeasure, selection: selectedRange,
      cursors: editor.state.cursors)
    body()
    guard let finished = transaction else { return }
    transaction = nil
    commit(finished)
  }

  /// 編集の束を 1 回の知らせで文書へ渡し、戻ったら写しを引く（取引の中だけ）。束を当てた後の本文を返す。
  func deliver(_ batch: EditBatch) -> TextRope? {
    guard let delegate, transaction != nil,
      let before = transaction?.content?.text ?? material.read().content?.text
    else { return nil }
    delegate.surface(self, didChange: batch.edits)
    let content = delegate.surfaceContent(self)
    transaction?.content = content
    transaction?.edited = true
    // 文書は束を後ろから当てる。後ろの編集は前の行を動かさないので、どの編集の行も束の前の本文で数えられる。
    transaction?.rowEdits += batch.edits.reversed().map {
      RowEdit($0, in: before, version: content.version)
    }
    return content.text
  }

  private func commit(_ finished: Transaction) {
    let cursors = editor.state.cursors
    let moved = finished.edited || cursors != finished.cursors
    let caret = CaretMaterial(
      selections: cursors.all.map(\.selection).filter { $0.length > 0 }.sorted {
        $0.location < $1.location
      },
      carets: cursors.all.map(\.position), epoch: CACurrentMediaTime(), focused: focused)
    let content = finished.content
    let marks = finished.marks.flatMap { spans in
      (content?.text ?? material.read().content?.text).map { RowMarks(spans, in: $0) }
    }
    let stroke = keystroke
    keystroke = nil
    let rowEdits = finished.rowEdits
    if finished.remeasure, let content { scroll.remeasure(from: content.version) }
    let revision = material.update {
      if let content { $0.content = content }
      if let marks { $0.marks = marks }
      for edit in rowEdits { $0.note(edit) }
      if let stroke { $0.keystrokes.append(stroke) }
      let epoch = moved ? caret.epoch : $0.caret.epoch
      $0.caret = caret
      $0.caret.epoch = epoch
    }
    updateLimits(heldUntil: revision)
    if let p = finished.scrollTo { scroll.place(p, heldUntil: revision) }
    reveal(finished.reveal, heldUntil: revision)
    wake()
    if selectedRange != finished.selection { delegate?.surfaceDidChangeSelection(self) }
    refreshViewport()
  }
}
