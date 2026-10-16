import Foundation

/// 列の選択・キー・押下（検索結果の列と同じ型。→ `ScmListSource`）。
extension ScmPanel {
  /// 選んだファイル行を開く（見出し・選択なしは開かない）。
  func openSelection(_ opening: Opening) {
    navigation.drop()
    guard let selection, let path = selection.path else { return }
    let kind: EditorDiff.Kind = selection.section == .staged ? .staged : .workingTree
    onOpenDiff(EditorDiff.Key(root: root, path: path, kind: kind), opening)
  }

  /// 渡れる行（区分見出しとファイル行）の位置。
  private func navigable(_ row: Int) -> Bool { layout.id(at: row) != nil }

  /// ↑↓: 渡れる行だけを渡る。未選択なら先頭。ファイル行へ動けば仮で開く（間引く）。
  func moveSelection(by delta: Int, isRepeat: Bool) {
    let rows = layout.items.indices
    guard !rows.isEmpty else { return }
    let before = selection
    var row: Int?
    if let selection, let current = layout.index[selection] {
      var next = current + delta
      while rows.contains(next), !navigable(next) { next += delta }
      row = rows.contains(next) ? next : nil
    } else {
      row = rows.first(where: navigable)
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
  func moveRight(isRepeat: Bool) {
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

  /// ⌘↑: 先頭の行（か未選択）ならメッセージ欄へ戻る。
  func returnToMessageIfAtTop() {
    let top = layout.items.indices.first(where: navigable)
    guard selection.map({ layout.index[$0] == top }) ?? true, isControlsOpen else { return }
    requestFocus(.message)
  }

  // MARK: - 押下

  func click(_ row: Int) {
    guard row < layout.items.count else { return }
    switch layout.items[row] {
    case .header(let section, _, _):
      select(ScmRowID(section: section, path: nil))
      toggle(section)
    case .file:
      select(layout.id(at: row))
      openSelection(.browse)
    case .more:
      showMoreCommits()
    case .branch, .commit:
      break
    }
  }

  func doubleClick(_ row: Int) {
    guard row < layout.items.count, case .file = layout.items[row] else { return }
    select(layout.id(at: row))
    openSelection(.commit)
  }

  /// 行の中の部品を押した。押せない姿の部品は何もしない。
  func press(_ row: Int, _ control: ScmControl) {
    guard row < layout.items.count else { return }
    switch layout.items[row] {
    case .header(let section, _, _):
      let files = changes.files(in: section).filter { !$0.isConflicted }
      switch control {
      case .unstageAll where !files.isEmpty: self.control.unstage(files.map(\.row))
      case .stageAll where !files.isEmpty: self.control.stage(files.map(\.row))
      case .discardAll where !files.isEmpty: onDiscard(files)
      case .refreshGraph: readGraphAndHead()
      default: break
      }
    case .file(_, let file):
      switch control {
      case .openFile where file.existsInWorkingTree:
        onOpenFile(URL(fileURLWithPath: root).appendingPathComponent(file.path))
      case .stage: self.control.stage([file.row])
      case .unstage: self.control.unstage([file.row])
      case .discard where !file.isConflicted: onDiscard([file])
      default: break
      }
    default:
      break
    }
  }
}

/// 行の中の部品（行の view が位置から答え、パネルが意味へ写す）。
enum ScmControl: Int {
  case openFile, discard, stage, unstage
  case discardAll, stageAll, unstageAll
  case refreshGraph
}
