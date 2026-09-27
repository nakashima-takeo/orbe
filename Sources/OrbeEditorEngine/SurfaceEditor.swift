import AppKit
import OrbeEditorCore
import os

/// 面の編集係（main）。編集の状態（カーソルの列・マーク・直前がキルだったか）と面ごとの undo を持ち、本文を変える唯一の道
/// ——打鍵も undo も丸ごと置き換えも、ここから面の取引を通って文書へ渡る。undo が知らない本文の変化は起こりえないので、
/// undo の要素と本文は食い違わない。
///
/// undo は NSUndoManager を入れ物にし（Edit メニューの有効・無効と `undoManager` を読む部品がそのまま効く）、要素 1 つを
/// 1 回だけ登録する。まとめ方は純関数（`UndoCoalescing`）が決め、まとまりが続く間は開いている要素に束を合成していく。
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
  private unowned let surface: MetalTextSurface

  init(surface: MetalTextSurface) {
    self.surface = surface
  }

  // MARK: - 操作

  /// コマンド 1 回を 1 つの取引で行う。
  func perform(_ command: EditCommand) {
    guard let env = surface.editingEnvironment() else { return }
    let before = state
    let result = EditCommands.run(command, before, env)
    surface.transact(reveal: result.reveal) {
      if result.edits.isEmpty {
        if result.state.cursors != before.cursors { close() }
      } else {
        record(result.edits, kind: result.undo, from: before.cursors, to: result.state.cursors, env.text)
      }
      state = result.state
    }
    if let kill = result.kill { KillBuffer.contents = kill }
  }

  /// カーソルの列を直接置く（マウス・行番号の列）。編集を伴わないので undo のまとまりを切る。
  func select(_ cursors: CursorList, reveal: Reveal) {
    guard let length = surface.textLength else { return }
    var cursors = cursors.map { $0.clamped(to: length) }
    cursors.normalize()
    surface.transact(reveal: reveal) {
      if cursors != state.cursors { close() }
      state = EditState(cursors: cursors, mark: state.mark)
    }
  }

  /// 外から選択を置く（契約の `selectedRange`）。カーソルは 1 本になり、undo のまとまりが切れる。見せない。
  func setSelection(_ range: NSRange) {
    select(CursorList(.selecting(range)), reveal: .none)
  }

  /// 本文を丸ごと置き換える（外部変更の差し替え）。変わらない先頭と末尾を落とした 1 つの編集として undo に載り、前後で
  /// まとまりを切る。選択は解け、キャレットは同じオフセット（本文が短ければ末尾）。
  func replaceAll(with text: String) {
    guard let current = surface.editingEnvironment()?.text else { return }
    let whole = TextEdit(range: NSRange(location: 0, length: current.length), replacement: text)
    let edit = whole.narrowed(replacing: current.units(in: whole.range))
    let caret = min(state.cursors.primary.selection.location, whole.replacementLength)
    close()
    surface.transact(reveal: .none, remeasure: true) {
      record(EditBatch([edit]), kind: .other, from: state.cursors, to: CursorList(Cursor(caret)), current)
      state = EditState(
        cursors: CursorList(Cursor(caret)), mark: state.mark.map { min($0, whole.replacementLength) })
    }
    close()
  }

  /// undo の区切り（保存・外部変更の差し替え）。
  func markBoundary() {
    close()
  }

  // MARK: - undo

  /// 束を文書へ渡し、undo に積む（まとまりが続けば開いている要素に合成する）。
  private func record(
    _ batch: EditBatch, kind proposed: UndoKind, from before: CursorList, to after: CursorList,
    _ text: TextRope
  ) {
    let kind = UndoCoalescing.resolve(proposed, after: open?.kind)
    let removed = batch.edits.contains { text.units(in: $0.range).contains(0x0A) }
    let joins = removed && (kind == .deletingLeft || kind == .deletingRight)
    let starts = UndoCoalescing.startsNewElement(
      after: open?.kind, kind, joinsLines: joins, editCount: batch.edits.count)
    if starts { close() }
    guard let result = surface.deliver(batch) else { return }
    if let open, !starts {
      open.append(batch, result: result, kind: kind, after: after)
    } else {
      let element = UndoElement(base: text, forward: batch, kind: kind, before: before, after: after)
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
  private func apply(_ batch: EditBatch, expecting contents: [ContiguousArray<UInt16>], restoring cursors: CursorList)
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
