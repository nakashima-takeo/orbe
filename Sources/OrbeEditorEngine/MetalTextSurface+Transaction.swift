import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// 面の取引——入力の出来事 1 つ（打鍵・マウスの出来事・IME の呼び出しの一連）で起きたことを、取引の終わりに 1 回だけ確定し、
/// 出す前の状態（→ `Pending`）に積む。出来事の中で呼ばれたコマンドは同じ取引に入り、外側の取引が 1 回だけ確定する（編集の
/// 状態と文書はその場で変わる——出来事の中で続く呼び出しは、それを読み返せる）。箱へ書いて描画スレッドを起こすのは確定の
/// その場ではなく、出す 1 か所（→ `flush`）。
///
/// 取引は面のもの（材料への書き込み・置く位置・打鍵の時刻・焦点）で、場の差分（取引の前の状態・写し・変わった行）は
/// 場ごとに持つ（→ `SiteChange`）。
struct Transaction {
  /// 取引の中で届いた行の印。
  var marks: LineMarkSpans?
  /// 取引の中で頼まれた、材料のほかの欄（見え方・焦点・大きさ）の書き込み。
  var writes: [@Sendable (inout FrameMaterial) -> Void] = []
  var reveal = Reveal.none
  /// 見せる区間（nil なら主のキャレット）。
  var revealing: NSRange?
  /// 見せ方の前に置くスクロールの位置（スクロールだけのキー・ドラッグの自動スクロール）。
  var scrollTo: SIMD2<Double>?
  /// 取引を起こした打鍵の出来事の時刻（打鍵→画面の遅れを、本文と同じ書き込みで材料へ添える）。
  var keystroke: Double?
  /// 取引の中で差し込みや区画の高さを変える前の縦の並び（変えなければ nil。面自身の編集でずらすのは含めない）。
  var anchor: RowLayout?
  /// 取引の前の縦の並びの版。
  let rowsVersion: Int
  /// 取引の前の焦点。
  let focused: Bool
}

extension MetalTextSurface {
  /// 今の写し（本文の場の写し）。
  var currentContent: SurfaceContent? { bodySite.currentContent }

  /// 今の写しの長さ。
  var textLength: Int? { currentContent?.text.length }

  /// 取引の中で `body` を行う。取引の中から呼ばれれば同じ取引に入り（位置・打鍵の時刻は後から頼んだものが勝つ）、そうで
  /// なければ取引を開き、終わりに 1 回だけ確定して出す前の状態に積む。`body` の間に文書から届く知らせ（行の印・役割の
  /// 変化）と材料への書き込みは控えるだけにする。打鍵の中の IME の呼び出しは打鍵の取引に入り、描くのは打鍵の後の 1 状態
  /// だけ。場の見せ方・測り直しは場の取引（`EditingSite.transact`）で頼む。
  func transact(
    scrollTo: SIMD2<Double>? = nil, keystroke: Double? = nil, _ body: () -> Void = {}
  ) {
    let opens = transaction == nil
    if opens {
      transaction = Transaction(rowsVersion: rows.version, focused: focused)
      bodySite.change = SiteChange(bodySite.editor)
    }
    if let scrollTo { transaction?.scrollTo = scrollTo }
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

  /// 取引を確定する——縦の並びの差し込みと区画の高さ（見えている先頭の文書の行を保つずらし）・行の数の上限・見せ方の
  /// 縦の位置・材料の書き込み（写し・行の印・変わった行・縦の並び・カーソル・打鍵の時刻・横の「見えるところまで」）を
  /// 出す前の状態に積み、選択と見えている範囲を知らせる。箱へは出す 1 か所（`flush`）が位置を先・材料を後の順で 1 回で
  /// 書く。
  private func commit(_ finished: Transaction) {
    guard let change = bodySite.change else { return }
    bodySite.change = nil
    editor.noteTransaction(
      from: change.cursors, edited: change.edited, restored: change.restoresCursors)
    let cursors = editor.state.cursors
    let composing = editor.isComposing || change.composing
    let text = change.content?.text ?? currentContent?.text
    if change.remeasure, let content = change.content { pending.remeasure = content.version }
    let lineCount = text?.lineCount ?? 1
    settleRows(finished, lineCount: lineCount)
    pending.limits = limits(lineCount: lineCount)
    if let text, let p = position(after: finished, cursors: cursors, text) {
      pending.position = p
    }
    if let content = change.content { pending.content = content }
    let restarts =
      change.edited || cursors != change.cursors || focused != finished.focused || composing
    pending.writes.append(bodyWrite(change, finished, text: text, restarts: restarts))
    flushLater()
    announce(
      selectionChanged: cursors.selections != change.cursors.selections
        || editor.state.continuation != change.continuation,
      composing: composing)
  }

  /// 本文の場の確定を材料へ書く 1 つの書き込み——取引の書き込み・写し・行の印・変わった行・打鍵の時刻・横の「見えるところ
  /// まで」・カーソル（変われば点滅を表示からやり直す）。
  private func bodyWrite(
    _ change: SiteChange, _ finished: Transaction, text: TextRope?, restarts: Bool
  ) -> @Sendable (inout FrameMaterial) -> Void {
    let cursors = editor.state.cursors
    let caret = caretMaterial(cursors)
    let content = change.content
    let marks = finished.marks.flatMap { spans in text.map { RowMarks(spans, in: $0) } }
    let rowEdits = change.rowEdits
    let writes = finished.writes
    let stroke = finished.keystroke
    if finished.reveal != .none { revealSerial += 1 }
    let caretRange = NSRange(location: cursors.primary.position, length: 0)
    let reveal =
      finished.reveal == .none
      ? nil : HorizontalReveal(range: finished.revealing ?? caretRange, serial: revealSerial)
    let edited = change.edited
    return { material in
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
  }

  /// 取引の中で変わった縦の並びを確定する——区画を今の幅で測り直し、差し込みや区画の高さが変わっていれば（位置を頼んだ
  /// 取引でなければ）見えている先頭の文書の行を同じ位置に保ち、変わった並びを材料への書き込みに積む。
  private func settleRows(_ finished: Transaction, lineCount: Int) {
    let unfitted = rows
    let refitted = refitZones(lineCount: lineCount)
    if let before = finished.anchor ?? (refitted ? unfitted : nil), finished.scrollTo == nil {
      keepFirstVisibleLine(from: before, lineCount: lineCount)
    }
    guard rows.version != finished.rowsVersion else { return }
    let rows = rows
    pending.writes.append { $0.rows = rows }
  }

  /// 確定した取引を知らせる——選択（変わったとき）・見えている範囲・変換中なら文字の座標。
  private func announce(selectionChanged: Bool, composing: Bool) {
    if selectionChanged { delegate?.surfaceDidChangeSelection(self) }
    refreshViewport()
    if composing { inputMethodCoordinatesDidChange() }
  }

  /// 選択の地・キャレット・変換中の文字。変換中は、変換に入った各カーソルのキャレットが IME の注目位置（主の注目位置と同じ
  /// 相対位置。文節を選んでいる間は無し）。
  private func caretMaterial(_ cursors: CursorList) -> CaretMaterial {
    let all = cursors.all
    let selections = all.map(\.selection).filter { $0.length > 0 }.sorted {
      $0.location < $1.location
    }
    let collapsed = all.filter { $0.selection.length == 0 }.map(\.position).sorted()
    guard let composition = editor.composition else {
      return CaretMaterial(
        selections: selections, carets: all.map(\.position).sorted(), collapsed: collapsed,
        epoch: CACurrentMediaTime(), focused: focused, blinks: caretBlinks)
    }
    let attention = composition.selection
    let offset = attention.location - composition.range.location
    let carets = all.indices.compactMap { index -> Int? in
      guard index < composition.marked.count, let marked = composition.marked[index] else {
        return all[index].position
      }
      return attention.length == 0 ? marked.location + offset : nil
    }
    return CaretMaterial(
      selections: selections, carets: carets.sorted(), collapsed: collapsed,
      epoch: CACurrentMediaTime(), focused: focused,
      blinks: caretBlinks,
      marked: MarkedMaterial(
        ranges: composition.marked.compactMap { $0 }.sorted { $0.location < $1.location },
        appearance: composition.appearance))
  }

  /// 変換の文字の座標が変わった（候補窓を追従させる）。変換中と変換の終わりだけ知らせる。選択の変化の知らせ
  /// （`textInputClientDidUpdateSelection`）は出さない——Writing Tools の印のための知らせで、受けた仕組みがその場で選択の
  /// 矩形を読み返し、長い行では打鍵のたびに main で行を組むことになる（Writing Tools は面で切ってある）。
  func inputMethodCoordinatesDidChange() {
    primarySite?.inputMethodCoordinatesDidChange()
  }
}
