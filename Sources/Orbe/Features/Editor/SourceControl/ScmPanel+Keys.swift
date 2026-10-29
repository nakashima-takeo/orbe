import Foundation

/// 変更の列の選択・キー・押下（検索結果の列と同じ型。→ `ScmListSource`）。
extension ScmPanel {
  /// 行の開き方。
  struct Opening: Equatable {
    let mode: EditorSession.OpenMode
    let focusesText: Bool

    /// シングルクリック・キーで行へ動いた: 仮で開き、焦点は列のまま。
    static let browse = Opening(mode: .preview, focusesText: false)
    /// ダブルクリック・Enter: 普通に開いて本文へ。
    static let commit = Opening(mode: .pinned, focusesText: true)
  }

  /// 選んだファイル行を開く（見出し・選択なしは開かない）。
  func openSelection(_ opening: Opening) {
    navigation.drop()
    guard let selection, let path = selection.path else { return }
    let kind: EditorDiff.Kind = selection.section == .staged ? .staged : .workingTree
    onOpenDiff(EditorDiff.Key(root: root, path: path, kind: kind), opening)
  }

  /// ↑↓: 子の見出しとファイル行を順に渡る。未選択なら先頭。ファイル行へ動けば仮で開く（間引く）。
  func moveSelection(by delta: Int, isRepeat: Bool, in layout: ScmLayout) {
    let rows = layout.items.indices
    guard !rows.isEmpty else { return }
    let before = selection
    var row: Int?
    if let selection, let current = layout.index[selection] {
      let next = current + delta
      row = rows.contains(next) ? next : nil
    } else {
      row = rows.first
    }
    if let row { select(layout.id(at: row)) }
    if selection != before, selection?.path != nil { navigation.didNavigate(isRepeat: isRepeat) }
  }

  /// ←: ファイル行なら区分の見出しへ、開いた見出しなら畳む。
  func moveLeft() {
    guard let selection else { return }
    if selection.path != nil {
      select(ScmRowID(section: selection.section, path: nil))
    } else if isOpen(selection.section) {
      toggle(selection.section)
    }
  }

  /// →: 畳んだ見出しなら開き、開いた見出しなら最初のファイル行へ動いて仮で開く（間引く）。
  func moveRight(isRepeat: Bool, in layout: ScmLayout) {
    guard let selection, selection.path == nil else { return }
    if !isOpen(selection.section) {
      toggle(selection.section)
    } else if let range = layout.fileRanges[selection.section], !range.isEmpty {
      select(layout.id(at: range.lowerBound))
      navigation.didNavigate(isRepeat: isRepeat)
    }
  }

  /// Enter: ファイル行は普通に開いて本文へ、見出しは開閉。
  func activateSelection() {
    guard let selection else { return }
    if selection.path == nil {
      toggle(selection.section)
    } else {
      openSelection(.commit)
    }
  }

  /// ⌘↑: 先頭の行（か未選択）ならメッセージ欄へ戻る（列が見えていれば、同じ親の中の欄も見えている）。
  func returnToMessageIfAtTop() {
    let top = layout.items.indices.first
    guard selection.map({ layout.index[$0] == top }) ?? true else { return }
    requestFocus(.message)
  }

  // MARK: - 押下

  func click(_ row: Int, in layout: ScmLayout) {
    guard row < layout.items.count else { return }
    switch layout.items[row] {
    case .header(let section, _, _, _):
      select(ScmRowID(section: section, path: nil))
      toggle(section)
    case .file:
      select(layout.id(at: row))
      openSelection(.browse)
    }
  }

  func doubleClick(_ row: Int, in layout: ScmLayout) {
    guard row < layout.items.count, case .file = layout.items[row] else { return }
    select(layout.id(at: row))
    openSelection(.commit)
  }

  /// 行の中の部品を押した（押せない姿の部品は列が渡さない）。ステージ・解除・確認を出さない破棄（ゴミ箱へ移すだけのもの）
  /// は、押した行と後継の行（同じ区分の次の行。無ければ前の行。区分の最後の 1 件なら後継なし）を錨として返す——同じ位置で
  /// 続けて押すと、次の行が次々に処理され、区分が尽きた後にポインタの下へ来たものは働かない。確認のシートを経る破棄と
  /// 見出しの一括操作は返さない。
  @discardableResult
  func press(_ row: Int, _ control: ScmControl, in layout: ScmLayout) -> RowListAnchor<ScmRowID>? {
    guard row < layout.items.count else { return nil }
    switch layout.items[row] {
    case .header:
      switch control {
      case .unstageAll where !changes.staged.isEmpty:
        unstage(changes.staged.map(\.row))
      case .stageAll where !changes.committable.isEmpty:
        stage(changes.committable.map(\.row))
      case .discardAll where !changes.discardable.isEmpty: onDiscard(changes.discardable)
      default: break
      }
    case .file(let section, let file):
      switch control {
      case .openFile:
        onOpenFile(URL(fileURLWithPath: root).appendingPathComponent(file.path))
      case .stage:
        stage([file.row])
        return layout.anchor(pressing: row, in: section)
      case .unstage:
        unstage([file.row])
        return layout.anchor(pressing: row, in: section)
      case .discard:
        onDiscard([file])
        return ScmDiscardGate.needsConfirmation([file])
          ? nil : layout.anchor(pressing: row, in: section)
      default: break
      }
    }
    return nil
  }
}

/// 行の中の部品（行の view が位置から答え、パネルが意味へ写す）。
enum ScmControl: Int {
  case openFile, discard, stage, unstage
  case discardAll, stageAll, unstageAll
}
