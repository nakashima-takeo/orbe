import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// 面の取引——入力の出来事 1 つ（打鍵・マウスの出来事・IME の呼び出しの一連）で起きたことを、取引の終わりに 1 回だけ確定し、
/// 出す前の状態（→ `Pending`）に積む。出来事の中で呼ばれたコマンドは同じ取引に入り、外側の取引が 1 回だけ確定する（編集の
/// 状態と文書はその場で変わる——出来事の中で続く呼び出しは、それを読み返せる）。箱へ書いて描画スレッドを起こすのは確定の
/// その場ではなく、出す 1 か所（→ `flush`）。
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
  /// 取引の前のカーソルの列と ⌘D の続きと焦点と、変換中だったか。
  let cursors: CursorList
  let continuation: SearchQuestion?
  let focused: Bool
  let composing: Bool
  /// 本文を変えたか。
  var edited = false
  /// カーソルの列を ⌘U で戻した（カーソルの履歴に積まない）。
  var restoresCursors = false
}

extension MetalTextSurface {
  /// 今の写し（取引が引いた最新の写し、無ければまだ出していない写し、無ければ出した写し）。
  var currentContent: SurfaceContent? {
    transaction?.content ?? pending.content ?? material.read().content
  }

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
      pageLines: max(1, lines - 2), indentation: indentation, lineBreak: lineBreak,
      killBuffer: KillBuffer.contents)
  }

  /// 取引の中で `body` を行う。取引の中から呼ばれれば同じ取引に入り（見せ方・位置・打鍵の時刻は後から頼んだものが勝ち、測り
  /// 直しは足し合わせる）、そうでなければ取引を開き、終わりに 1 回だけ確定して出す前の状態に積む。`body` の間に文書から
  /// 届く知らせ（行の印・役割の変化）と材料への書き込みは控えるだけにする。打鍵の中の IME の呼び出しは打鍵の取引に入り、
  /// 描くのは打鍵の後の 1 状態だけ。
  func transact(
    reveal: Reveal = .none, of range: NSRange? = nil, scrollTo: SIMD2<Double>? = nil,
    remeasure: Bool = false, keystroke: Double? = nil, _ body: () -> Void = {}
  ) {
    let opens = transaction == nil
    if opens {
      transaction = Transaction(
        cursors: editor.state.cursors, continuation: editor.state.continuation, focused: focused,
        composing: editor.isComposing)
    }
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

  /// 取引を確定する——行の数の上限・見せ方の縦の位置・材料の書き込み（写し・行の印・変わった行・カーソル・打鍵の時刻・
  /// 横の「見えるところまで」）を出す前の状態に積み、選択と見えている範囲を知らせる。箱へは出す 1 か所（`flush`）が
  /// 位置を先・材料を後の順で 1 回で書く。
  private func commit(_ finished: Transaction) {
    editor.noteTransaction(
      from: finished.cursors, edited: finished.edited, restored: finished.restoresCursors
    ) { [self] in
      scroll.peek(at: CACurrentMediaTime(), limits: pending.limits, place: pending.position)
        .position
    }
    let cursors = editor.state.cursors
    let composing = editor.isComposing || finished.composing
    let restarts =
      finished.edited || cursors != finished.cursors || focused != finished.focused || composing
    let text = finished.content?.text ?? currentContent?.text
    let caret = caretMaterial(cursors)
    let content = finished.content
    let marks = finished.marks.flatMap { spans in text.map { RowMarks(spans, in: $0) } }
    let rowEdits = finished.rowEdits
    let writes = finished.writes
    let stroke = finished.keystroke
    if finished.reveal != .none { revealSerial += 1 }
    let caretRange = NSRange(location: cursors.primary.position, length: 0)
    let reveal =
      finished.reveal == .none
      ? nil : HorizontalReveal(range: finished.revealing ?? caretRange, serial: revealSerial)
    let edited = finished.edited
    if finished.remeasure, let content { pending.remeasure = content.version }
    pending.limits = limits(lineCount: text?.lineCount ?? 1)
    if let text, let p = position(after: finished, cursors: cursors, text) {
      pending.position = p
    }
    if let content { pending.content = content }
    pending.writes.append { material in
      for write in writes { write(&material) }
      if let content { material.content = content }
      if let marks { material.marks = marks }
      for edit in rowEdits { material.note(edit) }
      if let stroke { material.keystrokes.append(stroke) }
      if reveal != nil || edited { material.reveal = reveal }
      let epoch = restarts ? caret.epoch : material.caret.epoch
      material.caret = caret
      material.caret.epoch = epoch
    }
    flushLater()
    announce(
      selectionChanged: cursors.selections != finished.cursors.selections
        || editor.state.continuation != finished.continuation,
      composing: composing)
  }

  /// 確定した取引を知らせる——選択（変わったとき）・見えている範囲・変換中なら文字の座標。
  private func announce(selectionChanged: Bool, composing: Bool) {
    if selectionChanged { delegate?.surfaceDidChangeSelection(self) }
    refreshViewport()
    if composing { inputMethodCoordinatesDidChange() }
  }

  /// 選択の地・キャレット・変換中の文字。変換中のキャレットは IME の注目位置（文節を選んでいる間は無し）。
  private func caretMaterial(_ cursors: CursorList) -> CaretMaterial {
    let composition = editor.composition
    return CaretMaterial(
      selections: cursors.all.map(\.selection).filter { $0.length > 0 }.sorted {
        $0.location < $1.location
      },
      carets: composition.map { $0.selection.length == 0 ? [$0.selection.location] : [] }
        ?? cursors.all.map(\.position),
      epoch: CACurrentMediaTime(), focused: focused, blinks: caretBlinks,
      marked: composition.map { MarkedMaterial(range: $0.range, appearance: $0.appearance) })
  }

  /// 変換の文字の座標が変わった（候補窓を追従させる）。変換中と変換の終わりだけ知らせる。選択の変化の知らせ
  /// （`textInputClientDidUpdateSelection`）は出さない——Writing Tools の印のための知らせで、受けた仕組みがその場で選択の
  /// 矩形を読み返し、長い行では打鍵のたびに main で行を組むことになる（Writing Tools は面で切ってある）。
  func inputMethodCoordinatesDidChange() {
    textView.inputContext?.invalidateCharacterCoordinates()
  }
}
