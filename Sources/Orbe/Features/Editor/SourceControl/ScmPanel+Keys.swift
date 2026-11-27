import Foundation

/// 変更の列の選択・キー・押下（検索結果の列と同じ型。→ `ScmListSource`）。
extension ScmPanel {
  /// 変更の列の状態。git 管理外・親「ソース管理」を畳んでいる（列が左の列に出ていない）なら無い。行があればある。
  /// 無ければ、git 管理下かの判定の前・行が今の status からまだ出来ていない間はこれから来る、それ以外（変更なし）は無い。
  var listState: EditorListState {
    if isManaged == false || !isRepositoryOpen { return .none }
    if !layout.items.isEmpty { return .rows }
    return isManaged == nil || rowsArePending ? .coming : .none
  }

  /// 列の状態を観測し、`reported` から変わったら知らせる。状態を決める値（判定・親の開閉・行の組・status から行を作って
  /// いるか〔`changesAreStale`・`buildJob`〕）はどれも観測するので、どの道で変わってもここが知らせる。
  func observeListState(_ reported: EditorListState) {
    withObservationTracking {
      _ = listState
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        let state = self.listState
        if state != reported { self.onListStateChange() }
        self.observeListState(state)
      }
    }
  }

  /// 行の開き方。
  struct Opening: Equatable {
    let focusesText: Bool

    /// シングルクリック・キーで行へ動いた: 開き、焦点は列のまま。
    static let browse = Opening(focusesText: false)
    /// ダブルクリック・Enter: 開いて本文へ。
    static let commit = Opening(focusesText: true)
  }

  /// 選んだファイル行を開く（見出し・選択なしは開かない）。
  func openSelection(_ opening: Opening) {
    navigation.drop()
    guard let selection, let key = diffKey(of: selection) else { return }
    onOpenDiff(key, opening)
  }

  /// 行 `id` の diff（見出しは nil）。「ステージされている変更」はステージ済み diff、「変更」は作業ツリー diff。
  func diffKey(of id: ScmRowID) -> EditorDiff.Key? {
    guard let path = id.path else { return nil }
    return EditorDiff.Key(
      root: root, path: path, kind: id.section == .staged ? .staged : .workingTree)
  }

  /// diff `key` の行（作業ツリー diff は「変更」、ステージ済み diff は「ステージされている変更」の、そのパスの行）。
  func rowID(of key: EditorDiff.Key) -> ScmRowID {
    ScmRowID(section: key.kind == .staged ? .staged : .changes, path: key.path)
  }

  /// diff `key` の行のファイル（区分を畳んでいても引ける。行が無ければ nil）。
  func file(of key: EditorDiff.Key) -> ScmChanges.File? {
    changes.file(in: rowID(of: key).section, path: key.path)
  }

  /// 行 `id` の祖先（親「ソース管理」とその区分）を開き、行が組に在れば選ぶ。区分を開いた後の組み直しを待つ間と、status が
  /// まだ届かない間は、行が組に無いので選ばない。選んだら true。
  func reveal(_ id: ScmRowID) -> Bool {
    setRepositoryOpen(true)
    if !isOpen(id.section) { toggle(id.section) }
    guard layout.index[id] != nil else { return false }
    select(id)
    return true
  }

  /// 本体に自動で開く行——選んでいるファイル行、無ければ先頭のファイル行（ファイル行が無ければ nil）。
  var rowToOpen: ScmRowID? {
    if let selection, selection.path != nil, layout.index[selection] != nil { return selection }
    return layout.items.indices.lazy.compactMap(layout.id(at:)).first { $0.path != nil }
  }

  /// ↑↓: 子の見出しとファイル行を順に渡る。未選択なら先頭。ファイル行へ動けば diff を開く（間引く）。
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

  /// →: 畳んだ見出しなら開き、開いた見出しなら最初のファイル行へ動いて diff を開く（間引く）。
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
  /// 続けて押すと、次の行が次々に処理され、区分が尽きた後にポインタの下へ来たものは働かない。確認を経る破棄と
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
