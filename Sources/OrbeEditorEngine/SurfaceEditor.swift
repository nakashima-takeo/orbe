import AppKit
import OrbeEditorCore
import os

/// 編集の場の編集係（main）。編集の状態（カーソルの列・マーク・直前がキルだったか）と場ごとの undo と変換中の状態を持ち、
/// 場の文を変える唯一の道——打鍵も変換も undo も丸ごと置き換えも、ここから面の取引を通って場の文の出どころ（本文の場なら
/// 文書）へ渡る。undo の履歴と変換の状態を合わせれば文のすべての変化を知っているので、undo の要素と文は食い違わない。
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
  /// カーソルの履歴（⌘U。VS Code の `CursorUndoRedoController`）——本文を変えずにカーソルの列が変わった取引の、前の列と
  /// スクロールの位置。古いものから `cursorHistoryLimit` 段まで持ち、本文が変わると消える。
  private var cursorHistory: [(cursors: CursorList, scroll: SIMD2<Double>)] = []
  static let cursorHistoryLimit = 50
  private unowned let site: EditingSite

  init(site: EditingSite) {
    self.site = site
  }

  var isComposing: Bool { composition != nil }

  // MARK: - 操作（IME 以外の入口）

  /// コマンド 1 回を 1 つの取引で行う（変換の確定も同じ取引に入る）。読むだけの場では、文を変えるコマンドは何もしない。
  func perform(_ command: EditCommand) {
    guard site.isEditable || !command.edits else { return }
    site.transact {
      finishComposition(.commit)
      guard let env = site.editingEnvironment() else { return }
      let before = state
      let result = EditCommands.run(command, before, env)
      site.transact(reveal: result.reveal, of: result.revealing) {
        record(
          result.edits, kind: result.undo, from: before.cursors, to: result.state.cursors, env.text)
        state = result.state
      }
      if let kill = result.kill { KillBuffer.contents = kill }
    }
  }

  /// カーソルの列を直接置く（マウス・行番号の列）。編集を伴わないので undo のまとまりを切る。`range` は見せる区間（nil なら
  /// 主のキャレット）。
  func select(_ cursors: CursorList, reveal: Reveal, of range: NSRange? = nil) {
    site.transact(reveal: reveal, of: range) {
      finishComposition(.commit)
      guard let length = site.textLength else { return }
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

  /// 本文を丸ごと置き換える（外部変更の差し替え）。変わらない先頭と末尾を落とした 1 つの編集として undo に載り（読むだけの
  /// 場では載せず、それまでの取り消しも捨てる——undo の要素と文を食い違わせない）、前後でまとまりを切る。選択は解け、
  /// キャレットは同じオフセット（本文が短ければ末尾）。変換中なら先に取り消す。
  func replaceAll(with text: String) {
    site.transact(remeasure: true) {
      finishComposition(.cancel)
      guard let current = site.editingEnvironment()?.text else { return }
      let whole = TextEdit(range: NSRange(location: 0, length: current.length), replacement: text)
      let edit = whole.narrowed(replacing: current.units(in: whole.range))
      let caret = min(state.cursors.primary.selection.location, whole.replacementLength)
      if site.isEditable {
        record(
          EditBatch([edit]), kind: .other, from: state.cursors, to: CursorList(Cursor(caret)),
          current)
      } else if current.units(in: edit.range) != edit.replacement {
        close()
        guard site.deliver(EditBatch([edit])) != nil else { return }
        undoManager.removeAllActions()
      }
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

  /// 焦点を失った。⌘D・⌘⇧L の続きを終える（VS Code と同じく、焦点が戻っても続かない）。
  func focusDidLeave() {
    guard state.continuation != nil else { return }
    site.transact { state.continuation = nil }
  }

  // MARK: - カーソルの履歴（⌘U）

  /// 取引の確定が呼ぶ。本文を変えた取引は履歴を消す。本文を変えずに選択が変わった取引は、前の列と、そのときのスクロールの
  /// 位置を積む（直前に積んだものと同じなら積まない。⌘U で戻した取引は積まない）。1 打鍵にセレクタが 2 つ届いても、取引
  /// 1 つで 1 段。
  func noteTransaction(from before: CursorList, edited: Bool, restored: Bool) {
    guard !edited else { return cursorHistory.removeAll() }
    guard !restored, !state.cursors.selects(like: before),
      cursorHistory.last.map({ !$0.cursors.selects(like: before) }) ?? true
    else { return }
    cursorHistory.append((before, site.surface.scrollPosition))
    if cursorHistory.count > Self.cursorHistoryLimit { cursorHistory.removeFirst() }
  }

  /// ⌘U——最後に積んだカーソルの列とスクロールの位置へ戻す。
  func undoCursors() {
    site.transact {
      finishComposition(.commit)
      guard let last = cursorHistory.popLast() else { return }
      site.transact(scrollTo: last.scroll) {
        close()
        state = EditState(cursors: last.cursors, mark: state.mark)
        site.markCursorsRestored()
      }
    }
  }

  // MARK: - 変換（IME の入口）

  /// 未確定の文字を置く。`replacement`（文書の座標。指していなければ主の未確定、無ければ主の選択）を `string` で置き換え、
  /// 全カーソルに同じ相対位置で当てて、変換を始めるか続ける。`selected` は `string` の中の選択、`appearance` の範囲は
  /// `string` の先頭から。空の文字列は IME 自身の取り消しで、未確定を消した今の本文のまま変換を終える（NSTextView と同じく、
  /// 再変換で置き換えた元の字は戻さない）。
  func setMarkedText(
    _ string: String, selected: NSRange, replacement: NSRange, appearance: MarkedAppearance
  ) {
    guard !discarding, site.isEditable, let text = site.editingEnvironment()?.text else { return }
    guard composition != nil || !string.isEmpty else { return }
    let units = ContiguousArray(string.utf16)
    site.transact(reveal: .minimal) {
      guard let placed = compose(replacement, units, text) else { return }
      if units.isEmpty { return end(.commit) }
      guard var current = composition else { return }
      current.selection = CompositionRules.innerSelection(
        selected, at: placed.marked.location, length: units.count)
      current.appearance = appearance
      composition = current
    }
  }

  /// 確定の文字を入れる。変換中なら `replacement`（指していなければ主の未確定）を全カーソルで置き換えて確定で終え、そうで
  /// なければ打鍵（`replacement` が本文の範囲を指していれば、その範囲の置き換え）。範囲を指した置き換えの後の選択は
  /// NSTextView と同じ（`CompositionRules.selection`。変換中は IME の選択に当て、他のカーソルは自分の置き換えた範囲に
  /// 対して主と同じ相対の位置）。
  func insertText(_ string: String, replacement: NSRange) {
    guard !discarding, site.isEditable else { return }
    guard let composing = composition else {
      guard let length = site.textLength else { return }
      guard let range = CompositionRules.replacement(replacement, length: length) else {
        if !string.isEmpty { perform(.insert(string)) }
        return
      }
      return perform(.replace(range, string))
    }
    guard let text = site.editingEnvironment()?.text else { return }
    site.transact(reveal: .minimal) {
      if let placed = compose(replacement, ContiguousArray(string.utf16), text),
        let marked = composition?.marked, let length = site.textLength
      {
        let inner = CompositionRules.selection(composing.selection, after: placed.edit)
        let offset = inner.location - placed.edit.range.location
        let cursors = zip(state.cursors.all, marked).map { cursor, range -> Cursor in
          guard let range else { return cursor }
          let start = min(max(0, range.location + offset), length)
          return .selecting(
            NSRange(location: start, length: min(start + inner.length, length) - start))
        }
        if let list = CursorList(cursors) { state.cursors = list }
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
    site.inputContext?.discardMarkedText()
    discarding = false
  }

  /// 変換の中の変化 1 つ——IME が指した範囲 `replacement`（文書の座標。指していなければ主の未確定、無ければ主の選択）を、
  /// 全カーソルに同じ相対位置で `units` に置き換える 1 つの束——を文書へ渡し（undo には積まない）、変換の状態へ合成する。
  /// 変換に入ったカーソルは自分の未確定の末尾。本文が変わらない置き換え（文節の選び直し）は文書へ渡さない。文書が受け
  /// なければ何も変えず nil。返すのは主の置き換え（束の前の座標）と主の新しい未確定。
  private func compose(
    _ replacement: NSRange, _ units: ContiguousArray<UInt16>, _ text: TextRope
  ) -> (edit: TextEdit, marked: NSRange)? {
    let cursors = state.cursors.all
    let selection = state.cursors.primary.selection
    let target = CompositionRules.target(
      replacement, marked: composition?.range, selection: selection, length: text.length)
    let bases = cursors.indices.map { index in
      composition.flatMap { index < $0.marked.count ? $0.marked[index] : nil }
        ?? cursors[index].selection
    }
    let targets = CompositionRules.targets(target, bases: bases, in: text)
    let accepted = CompositionRules.accepted(
      targets,
      candidates: composition.map { current in cursors.indices.map { current.marked[$0] != nil } })
    let order = cursors.indices.filter { accepted[$0] }.sorted {
      targets[$0].location < targets[$1].location
    }
    let batch = EditBatch(order.map { TextEdit(range: targets[$0], replacement: units) })
    let changed = EditBatch(batch.edits.filter { text.units(in: $0.range) != $0.replacement })
    guard let result = changed.isEmpty ? text : site.deliver(changed) else { return nil }
    var placed = [NSRange?](repeating: nil, count: cursors.count)
    for (index, range) in zip(order, batch.newRanges) { placed[index] = range }
    guard let primary = placed[0] else { return nil }
    let left = cursors.indices.filter { !accepted[$0] }
    var mapped = changed.map(left.flatMap { [cursors[$0].anchor, cursors[$0].position] })[...]
    let next = placed.map { range -> Cursor in
      if let range { return Cursor(NSMaxRange(range)) }
      let anchor = mapped.removeFirst()
      return Cursor(
        selectionStart: NSRange(location: anchor, length: 0), unit: .character,
        position: mapped.removeFirst())
    }
    var current =
      composition
      ?? Composition(
        marked: [], selection: selection, appearance: MarkedAppearance(),
        cursorsBefore: state.cursors, textBefore: text, changes: .empty, replacesCommitted: false)
    if !changed.isEmpty { current.changes = current.changes.then(changed, result: result) }
    current.replacesCommitted =
      current.replacesCommitted
      || CompositionRules.replacesCommitted(
        target, marked: composition?.range, selection: selection)
    current.marked = placed
    current.selection = NSRange(location: NSMaxRange(primary), length: 0)
    composition = current
    if let list = CursorList(next) {
      state = EditState(cursors: list, mark: state.mark.map(changed.map))
    }
    return (TextEdit(range: target, replacement: units), primary)
  }

  /// 変換を終える。確定なら変換の中の変化の正味を 1 回だけ undo に記録し、重なったカーソルをまとめる。取り消しなら変換が
  /// 無かったことにする——正味の変化の逆を文書へ渡し（再変換で置き換えた元の字も戻る）、カーソルを変換の前へ戻し、undo
  /// には触れない。
  private func end(_ how: CompositionEnd) {
    guard let finished = composition else { return }
    site.transact {
      composition = nil
      let net = CompositionRules.net(finished.changes, before: finished.textBefore)
      switch how {
      case .commit:
        state.cursors.normalize()
        guard !net.isEmpty else { return }
        register(
          net, kind: CompositionRules.undoKind(net, replacesCommitted: finished.replacesCommitted),
          from: finished.cursorsBefore, to: state.cursors, base: finished.textBefore)
      case .cancel:
        let backward = net.inverse(of: finished.textBefore)
        guard backward.isEmpty || site.deliver(backward) != nil else { return }
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
    guard site.deliver(batch) != nil else { return }
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
      guard let result = site.currentContent?.text else { return }
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
    guard let text = site.editingEnvironment()?.text else { return false }
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
    site.transact(reveal: .minimal) {
      guard site.deliver(batch) != nil else { return }
      state = EditState(cursors: cursors, mark: state.mark.map(batch.map))
    }
    return true
  }
}
