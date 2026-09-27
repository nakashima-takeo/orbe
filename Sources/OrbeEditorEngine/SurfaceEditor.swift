import AppKit
import OrbeEditorCore
import os

/// 面の編集係（main）。編集の状態（カーソルの列・マーク・直前がキルだったか）と面ごとの undo と変換中の状態を持ち、本文を
/// 変える唯一の道——打鍵も変換も undo も丸ごと置き換えも、ここから面の取引を通って文書へ渡る。undo の履歴と変換の状態を
/// 合わせれば本文のすべての変化を知っているので、undo の要素と本文は食い違わない。
///
/// undo は NSUndoManager を入れ物にし（Edit メニューの有効・無効と `undoManager` を読む部品がそのまま効く）、要素 1 つを
/// 1 回だけ登録する。まとめ方は純関数（`UndoCoalescing`）が決め、まとまりが続く間は開いている要素に束を合成していく。
///
/// 入口は 2 種類ある。IME の入口（`setMarkedText`・`insertText`・`unmarkText`）は変換を始め、続け、終える。変換中の変化は
/// 文書へ渡すだけで undo には積まず、変換の終わりに正味の変化を 1 回だけ記録する。それ以外のすべての入口は、最初に変換を
/// 確定で終える（丸ごと置き換えは取り消しで終える）。
@MainActor
final class SurfaceEditor {
  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.orbe", category: "editor-undo")

  private(set) var state = EditState(cursors: CursorList(Cursor(0)))
  let undoManager: UndoManager = {
    let manager = UndoManager()
    manager.groupsByEvent = false
    return manager
  }()
  /// まとまりが続いている要素（打鍵の続き）。
  private var open: UndoElement?
  /// 変換中の状態（変換中でなければ nil）。
  private(set) var composition: Composition?
  /// IME に変換を捨てさせている最中（その間に IME から届く呼び出しは、終えた変換のものなので受けない）。
  private var discarding = false
  private unowned let surface: MetalTextSurface

  init(surface: MetalTextSurface) {
    self.surface = surface
  }

  var isComposing: Bool { composition != nil }

  // MARK: - 操作（IME 以外の入口）

  /// コマンド 1 回を 1 つの取引で行う（変換の確定も同じ取引に入る）。
  func perform(_ command: EditCommand) {
    surface.transact {
      finishComposition(.commit)
      guard let env = surface.editingEnvironment() else { return }
      let before = state
      let result = EditCommands.run(command, before, env)
      surface.transact(reveal: result.reveal) {
        record(
          result.edits, kind: result.undo, from: before.cursors, to: result.state.cursors, env.text)
        state = result.state
      }
      if let kill = result.kill { KillBuffer.contents = kill }
    }
  }

  /// カーソルの列を直接置く（マウス・行番号の列）。編集を伴わないので undo のまとまりを切る。
  func select(_ cursors: CursorList, reveal: Reveal) {
    surface.transact(reveal: reveal) {
      finishComposition(.commit)
      guard let length = surface.textLength else { return }
      var cursors = cursors.map { $0.clamped(to: length) }
      cursors.normalize()
      if cursors != state.cursors { close() }
      state = EditState(cursors: cursors, mark: state.mark)
    }
  }

  /// 外から選択を置く（契約の `selectedRange`）。カーソルは 1 本になり、undo のまとまりが切れる。見せない。
  func setSelection(_ range: NSRange) {
    select(CursorList(.selecting(range)), reveal: .none)
  }

  /// 本文を丸ごと置き換える（外部変更の差し替え）。変わらない先頭と末尾を落とした 1 つの編集として undo に載り、前後で
  /// まとまりを切る。選択は解け、キャレットは同じオフセット（本文が短ければ末尾）。変換中なら先に取り消す。
  func replaceAll(with text: String) {
    surface.transact(remeasure: true) {
      finishComposition(.cancel)
      guard let current = surface.editingEnvironment()?.text else { return }
      let whole = TextEdit(range: NSRange(location: 0, length: current.length), replacement: text)
      let edit = whole.narrowed(replacing: current.units(in: whole.range))
      let caret = min(state.cursors.primary.selection.location, whole.replacementLength)
      record(
        EditBatch([edit]), kind: .other, from: state.cursors, to: CursorList(Cursor(caret)), current
      )
      state = EditState(
        cursors: CursorList(Cursor(caret)),
        mark: state.mark.map { min($0, whole.replacementLength) })
    }
  }

  /// undo の区切り（保存・外部変更の差し替え）。
  func markBoundary() {
    finishComposition(.commit)
    close()
  }

  // MARK: - 変換（IME の入口）

  /// 未確定の文字を置く。`replacement`（文書の座標。指していなければ未確定、無ければ選択）を `string` で置き換え、変換を
  /// 始めるか続ける。`selected` は `string` の中の選択、`appearance` の範囲は `string` の先頭から。空の文字列は IME 自身の
  /// 取り消しで、未確定を消した今の本文のまま変換を終える（NSTextView と同じく、再変換で置き換えた元の字は戻さない）。
  func setMarkedText(
    _ string: String, selected: NSRange, replacement: NSRange, appearance: MarkedAppearance
  ) {
    guard !discarding, let text = surface.editingEnvironment()?.text else { return }
    guard composition != nil || !string.isEmpty else { return }
    let units = ContiguousArray(string.utf16)
    let target = target(replacement, in: text)
    surface.transact(reveal: .minimal) {
      compose(TextEdit(range: target, replacement: units), text)
      if units.isEmpty { return end(.commit) }
      guard var current = composition else { return }
      current.selection = CompositionRules.innerSelection(
        selected, at: target.location, length: units.count)
      current.appearance = appearance.shifted(by: target.location)
      composition = current
    }
  }

  /// 確定の文字を入れる。変換中なら `replacement`（指していなければ未確定）を置き換えて確定で終え、そうでなければ打鍵
  /// （`replacement` が本文の範囲を指していれば、その範囲の置き換え）。範囲を指した置き換えの後の選択は NSTextView と同じ
  /// （`CompositionRules.selection`。変換中は IME の選択に当てる）。
  func insertText(_ string: String, replacement: NSRange) {
    guard !discarding else { return }
    guard let composing = composition else {
      guard let length = surface.textLength else { return }
      guard let range = CompositionRules.replacement(replacement, length: length) else {
        if !string.isEmpty { perform(.insert(string)) }
        return
      }
      return perform(.replace(range, string))
    }
    guard let text = surface.editingEnvironment()?.text else { return }
    let edit = TextEdit(range: target(replacement, in: text), replacement: string)
    surface.transact(reveal: .minimal) {
      if compose(edit, text) {
        state.cursors = CursorList(
          .selecting(CompositionRules.selection(composing.selection, after: edit)))
      }
      end(.commit)
    }
  }

  /// 未確定の文字を確定として残す。
  func unmarkText() {
    guard !discarding else { return }
    end(.commit)
  }

  /// IME 以外の入口が変換を終える。終えたら IME にも知らせる（IME の古い未確定の範囲を残さない）。
  func finishComposition(_ how: CompositionEnd) {
    guard composition != nil else { return }
    end(how)
    discarding = true
    surface.textView.inputContext?.discardMarkedText()
    discarding = false
  }

  /// 置き換える範囲（`replacement` は文書の座標）。
  private func target(_ replacement: NSRange, in text: TextRope) -> NSRange {
    CompositionRules.target(
      replacement, marked: composition?.range, selection: state.cursors.primary.selection,
      length: text.length)
  }

  /// 変換の中の変化 1 つを文書へ渡し（undo には積まない）、変換の状態へ合成する。主のカーソルは未確定の末尾。本文が
  /// 変わらない呼び出し（文節の選び直し）は文書へ渡さない。文書が受けなければ何も変えず false。
  @discardableResult
  private func compose(_ edit: TextEdit, _ text: TextRope) -> Bool {
    let batch = EditBatch([edit])
    let committed = CompositionRules.replacesCommitted(
      edit.range, marked: composition?.range, selection: state.cursors.primary.selection)
    let noop = text.units(in: edit.range) == edit.replacement
    guard let result = noop ? text : surface.deliver(batch) else { return false }
    var current =
      composition
      ?? Composition(
        range: edit.newRange, selection: NSRange(location: NSMaxRange(edit.newRange), length: 0),
        appearance: MarkedAppearance(), cursorsBefore: state.cursors, textBefore: text,
        changes: .empty, replacesCommitted: false)
    if !noop { current.changes = current.changes.then(batch, result: result) }
    current.replacesCommitted = current.replacesCommitted || committed
    current.range = edit.newRange
    current.selection = NSRange(location: NSMaxRange(edit.newRange), length: 0)
    composition = current
    state = EditState(
      cursors: CursorList(Cursor(NSMaxRange(edit.newRange))), mark: state.mark.map(batch.map))
    return true
  }

  /// 変換を終える。確定なら変換の中の変化の正味を 1 回だけ undo に記録する。取り消しなら変換が無かったことにする——正味の
  /// 変化の逆を文書へ渡し（再変換で置き換えた元の字も戻る）、カーソルを変換の前へ戻し、undo には触れない。
  private func end(_ how: CompositionEnd) {
    guard let finished = composition else { return }
    surface.transact {
      composition = nil
      let net = CompositionRules.net(finished.changes, before: finished.textBefore)
      switch how {
      case .commit:
        guard !net.isEmpty else { return }
        register(
          net, kind: CompositionRules.undoKind(net, replacesCommitted: finished.replacesCommitted),
          from: finished.cursorsBefore, to: state.cursors, base: finished.textBefore)
      case .cancel:
        let backward = net.inverse(of: finished.textBefore)
        guard backward.isEmpty || surface.deliver(backward) != nil else { return }
        state = EditState(cursors: finished.cursorsBefore, mark: state.mark.map(backward.map))
      }
    }
  }

  // MARK: - undo

  /// 束を文書へ渡し、undo に積む。中身を変えない編集（同じ字での上書き・大文字の語の大文字化・空のヤンク）は落とし、何も
  /// 残らなければ選択だけの変化にする——版も未保存の印も進めず、効き目の無い undo を積まない。
  private func record(
    _ edits: EditBatch, kind: UndoKind, from before: CursorList, to after: CursorList,
    _ text: TextRope
  ) {
    let batch = EditBatch(edits.edits.filter { text.units(in: $0.range) != $0.replacement })
    guard !batch.isEmpty else {
      if after != before { close() }
      return
    }
    guard surface.deliver(batch) != nil else { return }
    register(batch, kind: kind, from: before, to: after, base: text)
  }

  /// 文書へ渡し済みの束を undo に積む（まとまりが続けば開いている要素に合成する）。`base` は束の前の本文。
  private func register(
    _ batch: EditBatch, kind proposed: UndoKind, from before: CursorList, to after: CursorList,
    base: TextRope
  ) {
    let kind = UndoCoalescing.resolve(proposed, after: open?.kind)
    let removed = batch.edits.contains { base.units(in: $0.range).contains(0x0A) }
    let joins = removed && (kind == .deletingLeft || kind == .deletingRight)
    let starts = UndoCoalescing.startsNewElement(after: open?.kind, kind, joinsLines: joins)
    if starts { close() }
    if let open, !starts {
      guard let result = surface.currentContent?.text else { return }
      open.append(batch, result: result, kind: kind, after: after)
    } else {
      let element = UndoElement(
        base: base, forward: batch, kind: kind, before: before, after: after)
      open = element
      undoManager.beginUndoGrouping()
      undoManager.registerUndo(withTarget: self) { $0.undo(element) }
      undoManager.endUndoGrouping()
    }
    if kind == .other { close() }
  }

  /// 開いている要素を閉じる（逆向きの束を作り、最初の本文を手放す）。
  private func close() {
    open?.close()
    open = nil
  }

  private func undo(_ element: UndoElement) {
    close()
    guard let backward = element.backward else { return }
    guard apply(backward, expecting: element.forward.newRangesContent, restoring: element.before)
    else { return }
    undoManager.registerUndo(withTarget: self) { $0.redo(element) }
  }

  private func redo(_ element: UndoElement) {
    close()
    guard let backward = element.backward else { return }
    guard apply(element.forward, expecting: backward.newRangesContent, restoring: element.after)
    else { return }
    undoManager.registerUndo(withTarget: self) { $0.undo(element) }
  }

  /// undo・redo の束を、確かめてから同じ道で渡す——束の範囲が今の本文に収まり、置き換える中身が要素の記録と一致すること。
  /// 一致しなければ（あってはならない）本文に触れず、この面の undo を空にして記録を残す（空にするのは undo の手続きから
  /// 戻った後——手続きの中で入れ物を空にすると、入れ物が自分の組を閉じられない）。
  private func apply(
    _ batch: EditBatch, expecting contents: [ContiguousArray<UInt16>], restoring cursors: CursorList
  )
    -> Bool
  {
    guard let text = surface.editingEnvironment()?.text else { return false }
    let matches =
      batch.edits.count == contents.count
      && zip(batch.edits, contents).allSatisfy { edit, content in
        NSMaxRange(edit.range) <= text.length && text.units(in: edit.range) == content
      }
    guard matches else {
      Self.log.error("undo の要素が本文と一致しないので、この面の undo を空にした")
      DispatchQueue.main.async { [undoManager] in undoManager.removeAllActions() }
      return false
    }
    surface.transact(reveal: .minimal) {
      guard surface.deliver(batch) != nil else { return }
      state = EditState(cursors: cursors, mark: state.mark.map(batch.map))
    }
    return true
  }
}

/// undo の要素 1 つ——最初の本文に当てる前向きの束、閉じたときに作る逆向きの束、前後のカーソルの列。
@MainActor
final class UndoElement {
  private(set) var forward: EditBatch
  private(set) var backward: EditBatch?
  private(set) var kind: UndoKind
  let before: CursorList
  private(set) var after: CursorList
  /// 要素の前の本文（閉じるまで。逆向きの束を作るのに使う）。
  private var base: TextRope?

  init(base: TextRope, forward: EditBatch, kind: UndoKind, before: CursorList, after: CursorList) {
    self.base = base
    self.forward = forward
    self.kind = kind
    self.before = before
    self.after = after
  }

  /// まとまりの続きの束を合成する。`result` は束を当てた後の本文。
  func append(_ batch: EditBatch, result: TextRope, kind: UndoKind, after: CursorList) {
    forward = forward.then(batch, result: result)
    self.kind = kind
    self.after = after
  }

  func close() {
    guard let base else { return }
    backward = forward.inverse(of: base)
    self.base = nil
  }
}

extension EditBatch {
  /// 各編集の置換の中身（逆向きの束が置き換える、束の後の本文の中身）。
  var newRangesContent: [ContiguousArray<UInt16>] { edits.map(\.replacement) }
}
