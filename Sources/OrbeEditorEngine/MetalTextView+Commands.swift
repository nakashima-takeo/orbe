import AppKit

/// 標準のセレクタ（NSStandardKeyBindingResponding）→ 編集のコマンドの表。割り当ては macOS のキー割り当てに任せ、意味は
/// VS Code の同じ役のコマンドに合わせる（→ `EditCommands`）。`perform(#selector(...))` で呼ばれても効く。スクロールだけの
/// セレクタは編集の状態に触れず、面がスクロールの位置を置く。表に無いセレクタは AppKit の既定（responder chain で探し、
/// 無ければ警告音）。
extension MetalTextView {
  /// コマンドは面自身の入力（打鍵の中で届けば打鍵の処理の終わり、メニューから届けばその場で出す）。
  private func run(_ command: EditCommand) {
    surface?.inputScope { surface?.perform(command) }
  }

  private func move(_ movement: Movement, _ extending: Bool = false) {
    run(.move(movement, extending: extending))
  }

  // MARK: - 移動

  override func moveLeft(_ sender: Any?) { move(.left) }
  override func moveRight(_ sender: Any?) { move(.right) }
  override func moveBackward(_ sender: Any?) { move(.left) }
  override func moveForward(_ sender: Any?) { move(.right) }
  override func moveUp(_ sender: Any?) { move(.up) }
  override func moveDown(_ sender: Any?) { move(.down) }
  override func moveWordLeft(_ sender: Any?) { move(.wordLeft) }
  override func moveWordRight(_ sender: Any?) { move(.wordRight) }
  override func moveWordBackward(_ sender: Any?) { move(.wordLeft) }
  override func moveWordForward(_ sender: Any?) { move(.wordRight) }
  override func moveToLeftEndOfLine(_ sender: Any?) { move(.home) }
  override func moveToRightEndOfLine(_ sender: Any?) { move(.end) }
  override func moveToBeginningOfLine(_ sender: Any?) { move(.home) }
  override func moveToEndOfLine(_ sender: Any?) { move(.end) }
  override func moveToBeginningOfParagraph(_ sender: Any?) { move(.lineStart) }
  override func moveToEndOfParagraph(_ sender: Any?) { move(.lineEnd) }
  override func moveToBeginningOfDocument(_ sender: Any?) { move(.documentStart) }
  override func moveToEndOfDocument(_ sender: Any?) { move(.documentEnd) }
  override func pageUp(_ sender: Any?) { move(.pageUp) }
  override func pageDown(_ sender: Any?) { move(.pageDown) }

  override func moveLeftAndModifySelection(_ sender: Any?) { move(.left, true) }
  override func moveRightAndModifySelection(_ sender: Any?) { move(.right, true) }
  override func moveBackwardAndModifySelection(_ sender: Any?) { move(.left, true) }
  override func moveForwardAndModifySelection(_ sender: Any?) { move(.right, true) }
  override func moveUpAndModifySelection(_ sender: Any?) { move(.up, true) }
  override func moveDownAndModifySelection(_ sender: Any?) { move(.down, true) }
  override func moveWordLeftAndModifySelection(_ sender: Any?) { move(.wordLeft, true) }
  override func moveWordRightAndModifySelection(_ sender: Any?) { move(.wordRight, true) }
  override func moveWordBackwardAndModifySelection(_ sender: Any?) { move(.wordLeft, true) }
  override func moveWordForwardAndModifySelection(_ sender: Any?) { move(.wordRight, true) }
  override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { move(.home, true) }
  override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { move(.end, true) }
  override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { move(.home, true) }
  override func moveToEndOfLineAndModifySelection(_ sender: Any?) { move(.end, true) }
  override func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) {
    move(.lineStart, true)
  }
  override func moveToEndOfParagraphAndModifySelection(_ sender: Any?) { move(.lineEnd, true) }
  override func moveParagraphBackwardAndModifySelection(_ sender: Any?) {
    move(.paragraphBackward, true)
  }
  override func moveParagraphForwardAndModifySelection(_ sender: Any?) {
    move(.paragraphForward, true)
  }
  override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
    move(.documentStart, true)
  }
  override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
    move(.documentEnd, true)
  }
  override func pageUpAndModifySelection(_ sender: Any?) { move(.pageUp, true) }
  override func pageDownAndModifySelection(_ sender: Any?) { move(.pageDown, true) }

  // MARK: - スクロールだけ

  override func scrollPageUp(_ sender: Any?) { surface?.inputScope { surface?.scrollPages(-1) } }
  override func scrollPageDown(_ sender: Any?) { surface?.inputScope { surface?.scrollPages(1) } }
  override func scrollLineUp(_ sender: Any?) { surface?.inputScope { surface?.scrollLines(-1) } }
  override func scrollLineDown(_ sender: Any?) { surface?.inputScope { surface?.scrollLines(1) } }
  override func scrollToBeginningOfDocument(_ sender: Any?) {
    surface?.inputScope { surface?.scrollToDocumentEdge(end: false) }
  }
  override func scrollToEndOfDocument(_ sender: Any?) {
    surface?.inputScope { surface?.scrollToDocumentEdge(end: true) }
  }
  override func centerSelectionInVisibleArea(_ sender: Any?) { run(.centerSelection) }

  // MARK: - 選択

  override func selectAll(_ sender: Any?) { run(.selectAll) }
  override func selectLine(_ sender: Any?) { run(.selectLine) }
  override func selectParagraph(_ sender: Any?) { run(.selectLine) }
  override func selectWord(_ sender: Any?) { run(.selectWord) }

  // MARK: - 挿入

  override func insertText(_ insertString: Any) {
    insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
  }

  override func insertNewline(_ sender: Any?) { run(.newline(indents: true)) }
  override func insertParagraphSeparator(_ sender: Any?) { run(.newline(indents: true)) }
  override func insertLineBreak(_ sender: Any?) { run(.newline(indents: false)) }
  override func insertContainerBreak(_ sender: Any?) { run(.newline(indents: false)) }
  override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { run(.newline(indents: false)) }
  override func insertTab(_ sender: Any?) { run(.tab) }
  override func insertBacktab(_ sender: Any?) { run(.backtab) }
  override func insertTabIgnoringFieldEditor(_ sender: Any?) { run(.literalTab) }
  override func insertSingleQuoteIgnoringSubstitution(_ sender: Any?) { run(.insert("'")) }
  override func insertDoubleQuoteIgnoringSubstitution(_ sender: Any?) { run(.insert("\"")) }
  override func indent(_ sender: Any?) { run(.indent) }
  /// ⌃/——右から左の印（U+200F）と `/`（NSTextView と同じ）。
  @objc func insertRightToLeftSlash(_ sender: Any?) { run(.insert("\u{200F}/")) }

  // MARK: - 削除・キル・入れ替え・大小文字・マーク

  override func deleteBackward(_ sender: Any?) { run(.deleteBackward) }
  override func deleteForward(_ sender: Any?) { run(.deleteForward) }
  /// テンキーの Clear——選択を消す（NSTextView と同じ。選択が無ければ何もしない）。
  @objc func delete(_ sender: Any?) { run(.deleteSelection) }
  override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
    run(.deleteBackwardDecomposing)
  }
  override func deleteWordBackward(_ sender: Any?) { run(.deleteWordBackward) }
  override func deleteWordForward(_ sender: Any?) { run(.deleteWordForward) }
  override func deleteToBeginningOfLine(_ sender: Any?) { run(.deleteToLineStart) }
  override func deleteToEndOfLine(_ sender: Any?) { run(.deleteToLineEnd) }
  override func deleteToBeginningOfParagraph(_ sender: Any?) { run(.kill(forward: false)) }
  override func deleteToEndOfParagraph(_ sender: Any?) { run(.kill(forward: true)) }
  override func yank(_ sender: Any?) { run(.yank) }
  override func transpose(_ sender: Any?) { run(.transpose) }
  override func transposeWords(_ sender: Any?) { run(.transposeWords) }
  override func uppercaseWord(_ sender: Any?) { run(.changeCase(.upper)) }
  override func lowercaseWord(_ sender: Any?) { run(.changeCase(.lower)) }
  override func capitalizeWord(_ sender: Any?) { run(.changeCase(.capitalize)) }
  override func setMark(_ sender: Any?) { run(.setMark) }
  override func selectToMark(_ sender: Any?) { run(.selectToMark) }
  override func deleteToMark(_ sender: Any?) { run(.deleteToMark) }
  override func swapWithMark(_ sender: Any?) { run(.swapWithMark) }

  // MARK: - 何もしない・上へ渡す

  /// Esc は面では使わず、上の responder へ渡す（載せる側が検索バーを閉じるのに使う）。変換中（IME が使わなかった）は何も
  /// しない。
  override func cancelOperation(_ sender: Any?) {
    guard !composing else { return }
    nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
  }

  /// 補完は持たない。
  override func complete(_ sender: Any?) {}
  @objc func noop(_ sender: Any?) {}
  override func makeBaseWritingDirectionNatural(_ sender: Any?) {}
  override func makeBaseWritingDirectionLeftToRight(_ sender: Any?) {}
  override func makeBaseWritingDirectionRightToLeft(_ sender: Any?) {}
  override func makeTextWritingDirectionNatural(_ sender: Any?) {}
  override func makeTextWritingDirectionLeftToRight(_ sender: Any?) {}
  override func makeTextWritingDirectionRightToLeft(_ sender: Any?) {}

  // MARK: - undo

  /// 面の undo の入れ物。Edit メニューの ⌘Z / ⌘⇧Z の有効・無効と、`undoManager` を読む部品がこれを見る。
  override var undoManager: UndoManager? { surface?.editor.undoManager }

  /// Edit メニューの `undo:` が窓の既定の入れ物へ行かず面へ届くための中継。変換中（IME が ⌘Z を使わなかった）は変換を
  /// 取り消すだけで、undo の履歴に触れない。
  @objc func undo(_ sender: Any?) {
    surface?.inputScope {
      guard !composing else { return cancelComposition() }
      undoManager?.undo()
    }
  }

  @objc func redo(_ sender: Any?) {
    surface?.inputScope {
      guard !composing else { return cancelComposition() }
      undoManager?.redo()
    }
  }

  private func cancelComposition() {
    surface?.editor.finishComposition(.cancel)
  }
}

extension MetalTextView: NSMenuItemValidation {
  /// 変換中の取り消す・やり直すは、変換の取り消しとしていつも有効。コピー・カットはいつも有効（選択が空なら行を写す）。
  /// ペーストは平文かファイルがあるときだけ。
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(undo(_:))?: return composing || (undoManager?.canUndo ?? false)
    case #selector(redo(_:))?: return composing || (undoManager?.canRedo ?? false)
    case #selector(copy(_:))?, #selector(cut(_:))?: return true
    case #selector(paste(_:))?, #selector(pasteAsPlainText(_:))?: return canPaste
    default: return responds(to: menuItem.action)
    }
  }
}
