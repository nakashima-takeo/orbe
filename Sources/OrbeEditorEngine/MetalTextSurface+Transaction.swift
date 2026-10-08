import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// 面の取引——入力の出来事 1 つ（打鍵・マウスの出来事・IME の呼び出しの一連）で起きたことを、取引の終わりに 1 回だけ確定し、
/// 出す前の状態（→ `Pending`）に積む。出来事の中で呼ばれたコマンドは同じ取引に入り、外側の取引が 1 回だけ確定する（編集の
/// 状態と文書はその場で変わる——出来事の中で続く呼び出しは、それを読み返せる）。箱へ書いて描画スレッドを起こすのは確定の
/// その場ではなく、出す 1 か所（→ `flush`）。
///
/// 取引は面のもの（材料への書き込み・置く位置・打鍵の時刻・焦点と主）で、場の差分（取引の前の状態・写し・変わった行）は
/// 場ごとに持つ（→ `SiteChange`）。入力欄の打鍵も面の 1 つの取引で、入力欄の知らせの中で載せる側が区画を描き直せば、
/// 伸びた入力欄と打った字が同じコマに出る。
struct Transaction {
  /// 取引の中で届いた行の印。
  var marks: LineMarkSpans?
  /// 取引の中で頼まれた、材料のほかの欄（見え方・焦点・大きさ・区画）の書き込み。
  var writes: [@Sendable (inout FrameMaterial) -> Void] = []
  var reveal = Reveal.none
  /// 見せる区間（nil なら見せ方を頼んだ場の主のキャレット）と、見せ方を頼んだ場。
  var revealing: NSRange?
  var revealSite: EditingSite?
  /// 見せ方の前に置くスクロールの位置（スクロールだけのキー・ドラッグの自動スクロール）。
  var scrollTo: SIMD2<Double>?
  /// 取引を起こした打鍵の出来事の時刻（打鍵→画面の遅れを、本文と同じ書き込みで材料へ添える）。
  var keystroke: Double?
  /// 取引の中で差し込みや区画の高さを変える前の縦の並び（変えなければ nil。面自身の編集でずらすのは含めない）。
  var anchor: RowLayout?
  /// 取引の中で触れた入力欄の場（本文の場はいつも確定する）。
  var touched: [EditingSite] = []
  /// 取引の前の縦の並びの版。
  let rowsVersion: Int
  /// 取引の前の焦点と主。
  let focused: Bool
  let primary: Primary
}

extension MetalTextSurface {
  /// 今の写し（本文の場の写し）。
  var currentContent: SurfaceContent? { bodySite.currentContent }

  /// 取引の中で `body` を行う。取引の中から呼ばれれば同じ取引に入り（位置・打鍵の時刻は後から頼んだものが勝つ）、そうで
  /// なければ取引を開き、終わりに区画を今の幅に合わせ（→ `settleZones`）、1 回だけ確定して出す前の状態に積む。`body` の
  /// 間に文書から届く知らせ（行の印・役割の変化）と材料への書き込みは控えるだけにする。打鍵の中の IME の呼び出しは打鍵の
  /// 取引に入り、描くのは打鍵の後の 1 状態だけ。場の見せ方・測り直しは場の取引（`EditingSite.transact`）で頼む。
  func transact(
    scrollTo: SIMD2<Double>? = nil, keystroke: Double? = nil, _ body: () -> Void = {}
  ) {
    let opens = transaction == nil
    if opens {
      transaction = Transaction(rowsVersion: rows.version, focused: focused, primary: primary)
      bodySite.change = SiteChange(bodySite.editor)
    }
    if let scrollTo { transaction?.scrollTo = scrollTo }
    if let keystroke { transaction?.keystroke = keystroke }
    body()
    guard opens else { return }
    settleZones()
    guard let finished = transaction else { return }
    transaction = nil
    commit(finished)
  }

  /// 描く材料の欄を書く（取引の終わりの書き込みにまとめる）。
  func write(_ body: @escaping @Sendable (inout FrameMaterial) -> Void) {
    transact { transaction?.writes.append(body) }
  }

  /// 本文の場は主で、面に焦点がある。
  var bodyFocused: Bool { focused && primary == .body }

  /// 取引を確定する——縦の並びの差し込みと区画の高さ（見えている先頭の文書の行を保つずらし）・行の数の上限・見せ方の
  /// 縦の位置・材料の書き込み（写し・行の印・変わった行・縦の並び・カーソル・入力欄・打鍵の時刻・横の「見えるところ
  /// まで」）を出す前の状態に積み、選択と見えている範囲を知らせる。箱へは出す 1 か所（`flush`）が位置を先・材料を後の
  /// 順で 1 回で書く。
  private func commit(_ finished: Transaction) {
    guard let change = bodySite.change else { return }
    let span = finished.reveal == .none ? nil : finished.revealSite?.revealSpan(finished.revealing)
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
    if let p = position(after: finished, span: span) {
      pending.position = p
      Self.placementSerial += 1
      pending.placement = Self.placementSerial
    }
    if let content = change.content { pending.content = content }
    let refocused = focused != finished.focused || primary != finished.primary
    let restarts =
      change.edited || cursors != change.cursors || composing || refocused
    pending.writes.append(bodyWrite(change, finished, text: text, restarts: restarts))
    commitFields(finished, refocused: refocused)
    flushLater()
    announce(
      selectionChanged: cursors.selections != change.cursors.selections
        || editor.state.continuation != change.continuation,
      composing: composing || primarySite?.editor.isComposing == true)
  }

  /// 本文の場の確定を材料へ書く 1 つの書き込み——取引の書き込み・写し・行の印・変わった行・打鍵の時刻・横の「見えるところ
  /// まで」（本文の場が頼んだ見せ方だけ）・カーソル（変われば点滅を表示からやり直す）。
  private func bodyWrite(
    _ change: SiteChange, _ finished: Transaction, text: TextRope?, restarts: Bool
  ) -> @Sendable (inout FrameMaterial) -> Void {
    let cursors = editor.state.cursors
    let caret = bodySite.caretMaterial(focused: bodyFocused, blinks: caretBlinks)
    let content = change.content
    let marks = finished.marks.flatMap { spans in text.map { RowMarks(spans, in: $0) } }
    let rowEdits = change.rowEdits
    let writes = finished.writes
    let stroke = finished.keystroke
    let revealsBody = finished.reveal != .none && finished.revealSite === bodySite
    if revealsBody { revealSerial += 1 }
    let caretRange = NSRange(location: cursors.primary.position, length: 0)
    let reveal =
      revealsBody
      ? HorizontalReveal(range: finished.revealing ?? caretRange, serial: revealSerial) : nil
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

  /// 入力欄の場の確定——触れた場（焦点か主が変わればすべての場）の ⌘U の履歴・描く材料と、文かカーソルが変われば横の
  /// 「キャレットが見えるところまで」の頼み（描画スレッドが行を組んで解く）。
  private func commitFields(_ finished: Transaction, refocused: Bool) {
    let sites = refocused ? Array(fields.values) : finished.touched
    for site in sites {
      let change = site.change ?? SiteChange(site.editor)
      site.change = nil
      guard let field = site.field, site.zone != nil, let content = site.currentContent else {
        continue
      }
      site.editor.noteTransaction(
        from: change.cursors, edited: change.edited, restored: change.restoresCursors)
      var reveal: HorizontalReveal?
      if finished.revealSite === site || change.edited
        || change.cursors != site.editor.state.cursors
      {
        site.revealSerial += 1
        let caret = site.editor.state.cursors.primary.position
        reveal = HorizontalReveal(
          range: NSRange(location: caret, length: 0), serial: site.revealSerial)
      }
      let primary = self.primary == .field(field.id)
      let restarts =
        change.edited || change.cursors != site.editor.state.cursors || change.composing
        || site.editor.isComposing || refocused
      let caret = site.caretMaterial(focused: focused && primary, blinks: caretBlinks)
      let fieldMaterial = FieldMaterial(
        content: content, caret: caret, scroll: site.horizontal, reveal: reveal,
        font: field.style.font as CTFont, lineHeight: field.style.lineHeight,
        baseline: site.baseline, tabColumns: site.tabColumns, tabWidth: site.tabWidth,
        palette: fieldPalette(site, field))
      let serial = site.serial
      pending.writes.append { material in
        var written = fieldMaterial
        if !restarts, let epoch = material.fields[serial]?.caret.epoch {
          written.caret.epoch = epoch
        }
        if written.reveal == nil { written.reveal = material.fields[serial]?.reveal }
        material.fields[serial] = written
      }
    }
    for site in finished.touched { site.change = nil }
  }

  /// 入力欄の場の色（外観で解いたものを覚える）。
  private func fieldPalette(_ site: EditingSite, _ field: ZoneTextField) -> FieldPalette {
    if let palette = site.palette { return palette }
    let appearance = textView.effectiveAppearance
    let style = field.style
    let palette = FieldPalette(
      text: InkColor(style.textColor, appearance: appearance, space: space, scale: scale),
      caret: FrameColor(style.caretColor, appearance: appearance, space: space),
      selection: FrameColor(style.selectionColor, appearance: appearance, space: space),
      inactiveSelection: FrameColor(
        style.inactiveSelectionColor, appearance: appearance, space: space))
    site.palette = palette
    return palette
  }

  /// 取引の中で変わった縦の並びを確定する——差し込みや区画の高さが変わっていれば（位置を頼んだ取引でなければ）見えて
  /// いる先頭の文書の行を同じ位置に保ち、変わった並びを材料への書き込みに積む。
  private func settleRows(_ finished: Transaction, lineCount: Int) {
    if let before = finished.anchor, finished.scrollTo == nil {
      pending.anchored = true
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

  /// 変換の文字の座標が変わった（候補窓を追従させる）。変換中と変換の終わりだけ知らせる。選択の変化の知らせ
  /// （`textInputClientDidUpdateSelection`）は出さない——Writing Tools の印のための知らせで、受けた仕組みがその場で選択の
  /// 矩形を読み返し、長い行では打鍵のたびに main で行を組むことになる（Writing Tools は面で切ってある）。
  func inputMethodCoordinatesDidChange() {
    primarySite?.inputMethodCoordinatesDidChange()
  }
}
