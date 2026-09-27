import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// 面の取引——入力の出来事 1 つ（打鍵・マウスの出来事・IME の呼び出しの一連）で箱へ置くものを、取引の終わりに 1 回の書き込み
/// で確定する。描画スレッドは刻みごとに箱を読むので、出来事の途中で何度も書くと「新しい本文に古いキャレット」「スクロール
/// だけ先に動いた」コマが出る。出来事の中で呼ばれたコマンドは同じ取引に入り、外側の取引が 1 回だけ確定する（編集の状態と
/// 文書はその場で変わる——出来事の中で続く呼び出しは、それを読み返せる）。
struct Transaction {
  /// 取引の中で引いた文書の写し（引かなければ nil）。
  var content: SurfaceContent?
  /// 取引の中で届いた行の印。
  var marks: LineMarkSpans?
  /// 取引の中で渡した編集で、組版の変わった行（当てた順）。描画スレッドは変わった行だけを組み直す。
  var rowEdits: [RowEdit] = []
  /// 取引の中で頼まれた、材料のほかの欄（見え方・焦点・大きさ）の書き込み。
  var writes: [@Sendable (inout FrameMaterial) -> Void] = []
  var reveal = Reveal.none
  /// 見せる区間（nil なら主のキャレット）。
  var revealing: NSRange?
  /// 見せ方の前に置くスクロールの位置（スクロールだけのキー・ドラッグの自動スクロール）。
  var scrollTo: SIMD2<Double>?
  /// 最も長い行を測り直す（丸ごと置き換え）。
  var remeasure = false
  /// 取引を起こした打鍵の出来事の時刻（打鍵→画面の遅れを、本文と同じ書き込みで材料へ添える）。
  var keystroke: Double?
  /// 取引の前のカーソルの列と焦点。
  let cursors: CursorList
  let focused: Bool
  /// 本文を変えたか。
  var edited = false
}

extension MetalTextSurface {
  /// 今の写し（取引の中なら、取引が引いた最新の写し）。
  var currentContent: SurfaceContent? { transaction?.content ?? material.read().content }

  /// 今の写しの長さ。
  var textLength: Int? { currentContent?.text.length }

  /// 編集の規則が読む環境。
  func editingEnvironment() -> EditingEnvironment? {
    guard let text = currentContent?.text else { return nil }
    let lines = Int(
      (Double(size.height - config.topInset) / Double(config.lineHeight)).rounded(.down))
    return EditingEnvironment(
      text: text,
      geometry: ShapedLineGeometry(
        text: text, cache: lineStops, tabWidth: config.tabWidth(columns: indentation.unit)),
      pageLines: max(1, lines - 2), indentation: indentation, killBuffer: KillBuffer.contents)
  }

  /// 取引の中で `body` を行う。取引の中から呼ばれれば同じ取引に入り（見せ方・位置・打鍵の時刻は後から頼んだものが勝ち、測り
  /// 直しは足し合わせる）、そうでなければ取引を開き、終わりに 1 回だけ確定する。`body` の間に文書から届く知らせ（行の印・
  /// 役割の変化）と材料への書き込みは控えるだけにする。
  func transact(
    reveal: Reveal = .none, of range: NSRange? = nil, scrollTo: SIMD2<Double>? = nil,
    remeasure: Bool = false, keystroke: Double? = nil, _ body: () -> Void = {}
  ) {
    let opens = transaction == nil
    if opens { transaction = Transaction(cursors: editor.state.cursors, focused: focused) }
    if reveal != .none {
      transaction?.reveal = reveal
      transaction?.revealing = range
    }
    if let scrollTo { transaction?.scrollTo = scrollTo }
    if remeasure { transaction?.remeasure = true }
    if let keystroke { transaction?.keystroke = keystroke }
    body()
    guard opens, let finished = transaction else { return }
    transaction = nil
    commit(finished)
  }

  /// 描く材料の欄を書く（取引の終わりの書き込みにまとめる）。
  func write(_ body: @escaping @Sendable (inout FrameMaterial) -> Void) {
    transact { transaction?.writes.append(body) }
  }

  /// 編集の束を 1 回の知らせで文書へ渡し、戻ったら写しを引く（取引の中だけ）。束を当てた後の本文を返す（文書と結ばれて
  /// いなければ nil）。
  func deliver(_ batch: EditBatch) -> TextRope? {
    precondition(transaction != nil, "本文の変化は取引の中でだけ渡す")
    guard let delegate, let before = currentContent?.text else { return nil }
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

  /// 取引を確定する。材料の版を先に決め、行の数の上限と見せ方の位置をその版に結んでスクロールの箱へ置いてから、材料を 1 回
  /// で書く——描画スレッドは、新しい材料を読むまで前の位置を描き、読んだコマから新しい位置を描く（新しい本文を古い位置で
  /// 描くコマも、古い本文を新しい位置で描くコマも出ない）。それから描画スレッドを起こし、選択と見えている範囲を知らせる。
  private func commit(_ finished: Transaction) {
    let cursors = editor.state.cursors
    let restarts = finished.edited || cursors != finished.cursors || focused != finished.focused
    let text = finished.content?.text ?? material.read().content?.text
    let caret = CaretMaterial(
      selections: cursors.all.map(\.selection).filter { $0.length > 0 }.sorted {
        $0.location < $1.location
      },
      carets: cursors.all.map(\.position), epoch: CACurrentMediaTime(), focused: focused)
    let content = finished.content
    let marks = finished.marks.flatMap { spans in text.map { RowMarks(spans, in: $0) } }
    let rowEdits = finished.rowEdits
    let writes = finished.writes
    let stroke = finished.keystroke
    let revision = material.revision + 1
    if finished.remeasure, let content { scroll.remeasure(from: content.version) }
    updateLimits(lineCount: text?.lineCount ?? 1, heldUntil: revision)
    if let text, let p = position(after: finished, cursors: cursors, text) {
      scroll.place(p, heldUntil: revision)
    }
    let written = material.update {
      for write in writes { write(&$0) }
      if let content { $0.content = content }
      if let marks { $0.marks = marks }
      for edit in rowEdits { $0.note(edit) }
      if let stroke { $0.keystrokes.append(stroke) }
      let epoch = restarts ? caret.epoch : $0.caret.epoch
      $0.caret = caret
      $0.caret.epoch = epoch
    }
    precondition(written == revision, "描く材料の箱を書くのは main の取引だけ")
    wake()
    if cursors.primary.selection != finished.cursors.primary.selection {
      delegate?.surfaceDidChangeSelection(self)
    }
    refreshViewport()
  }
}
