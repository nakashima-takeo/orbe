import Foundation

/// PR のパネルの列の選択・キー・押下（ソース管理の変更の列と同じ型。→ `PrListSource`）。コミットの行と欠けの行は
/// 選べず押せない。
extension PrPanel {
  /// 選んだファイル行の PR の diff を開く（見出し・フォルダ・選択なしは開かない）。
  func openSelection(_ opening: ScmPanel.Opening) {
    navigation.drop()
    guard case .file(let path)? = selection, let key = diffKey(of: path) else { return }
    onOpenDiff(key, opening)
  }

  /// 変更ファイル `path` の、今の PR の diff（PR が無ければ nil）。
  func diffKey(of path: String) -> EditorDiff.Key? {
    state.map { EditorDiff.Key(root: root, path: path, kind: .pullRequest($0)) }
  }

  /// 本体に自動で開く変更ファイル——選んでいるファイル行、無ければ先頭のファイル行のパス（ファイル行が無ければ nil）。
  var fileToOpen: String? {
    if case .file(let path)? = selection, layout.index[.file(path)] != nil { return path }
    for row in layout.items.indices {
      if case .file(let path) = layout.id(at: row) { return path }
    }
    return nil
  }

  /// ↑↓: 選べる行を順に渡る。未選択なら先頭の選べる行。ファイル行へ動けば diff を開く（間引く）。
  func moveSelection(by delta: Int, isRepeat: Bool, in layout: PrLayout) {
    let selectable = layout.items.indices.filter { layout.id(at: $0).isSelectable }
    guard !selectable.isEmpty else { return }
    let before = selection
    if let selection, let current = layout.index[selection],
      let position = selectable.firstIndex(of: current)
    {
      let next = position + delta
      if selectable.indices.contains(next) { select(layout.id(at: selectable[next])) }
    } else {
      select(layout.id(at: selectable[0]))
    }
    if selection != before, case .file? = selection { navigation.didNavigate(isRepeat: isRepeat) }
  }

  /// ←: 開いた見出し・フォルダなら畳み、そうでなければ親（フォルダか区分の見出し）へ動く。
  func moveLeft(in layout: PrLayout) {
    switch selection {
    case .section(let section)? where isOpen(section): toggle(section)
    case .folder(let path)? where !closedFolders.contains(path): toggleFolder(path)
    case .folder(let path)?, .file(let path)?: select(parent(of: path, in: layout))
    default: break
    }
  }

  /// →: 畳んだ見出し・フォルダなら開き、開いていれば最初の子の行へ動く（ファイル行なら diff を開く）。
  func moveRight(isRepeat: Bool, in layout: PrLayout) {
    switch selection {
    case .section(let section)? where !isOpen(section): toggle(section)
    case .folder(let path)? where closedFolders.contains(path): toggleFolder(path)
    case .section?, .folder?:
      guard let current = selection.flatMap({ layout.index[$0] }),
        let child = layout.items.indices.first(where: {
          $0 > current && layout.id(at: $0).isSelectable
        })
      else { return }
      let id = layout.id(at: child)
      guard isChild(id, of: selection, in: layout) else { return }
      select(id)
      if case .file = id { navigation.didNavigate(isRepeat: isRepeat) }
    default: break
    }
  }

  /// Enter: ファイル行は普通に開いて本文へ、見出し・フォルダは開閉。
  func activateSelection() {
    switch selection {
    case .section(let section)?: toggle(section)
    case .folder(let path)?: toggleFolder(path)
    case .file?: openSelection(.commit)
    default: break
    }
  }

  // MARK: - 押下

  func click(_ row: Int, in layout: PrLayout) {
    guard row < layout.items.count else { return }
    switch layout.items[row] {
    case .section(let section, _, _):
      select(.section(section))
      toggle(section)
    case .folder(let path, _, _, _):
      select(.folder(path))
      toggleFolder(path)
    case .file(let path, _, _):
      select(.file(path))
      openSelection(.browse)
    case .commit, .olderCommits: break
    }
  }

  func doubleClick(_ row: Int, in layout: PrLayout) {
    guard row < layout.items.count, case .file(let path, _, _) = layout.items[row] else { return }
    select(.file(path))
    openSelection(.commit)
  }

  /// 行の中の部品を押した。チェックは確認済みの切り替え（フォルダは配下をまとめて）、変更ファイルの見出しの印はツリーと
  /// リストの切り替え。行のクリックにはならない。
  func press(_ row: Int, _ control: PrControl, in layout: PrLayout) {
    guard row < layout.items.count else { return }
    switch (layout.items[row], control) {
    case (.file(let path, _, _), .viewed): toggleViewed(path)
    case (.folder(_, _, _, let files), .viewed): toggleViewed(folder: files)
    case (.section(.files, _, _), .tree):
      onViewAsTree(true)
      rebuild()
    case (.section(.files, _, _), .list):
      onViewAsTree(false)
      rebuild()
    default: break
    }
  }

  // MARK: - 木の上の位置

  /// パス `path` の親の行（ツリーならフォルダ、無ければ変更ファイルの見出し）。
  private func parent(of path: String, in layout: PrLayout) -> PrRowID {
    let directory = (path as NSString).deletingLastPathComponent
    if !directory.isEmpty, layout.index[.folder(directory)] != nil { return .folder(directory) }
    return .section(.files)
  }

  /// `id` が `parent`（見出しかフォルダ）の直下の行か。
  private func isChild(_ id: PrRowID, of parent: PrRowID?, in layout: PrLayout) -> Bool {
    switch (parent, id) {
    case (.section(.files)?, .folder), (.section(.files)?, .file): true
    case (.folder(let folder)?, .folder(let path)), (.folder(let folder)?, .file(let path)):
      path.hasPrefix(folder + "/")
    default: false
    }
  }
}

/// PR のパネルの行の中の部品（行の view が位置から答え、パネルが意味へ写す）。
enum PrControl: Int {
  /// 確認済みのチェック（ファイル・フォルダ）。
  case viewed
  /// 変更ファイルの見出しの「ツリー表示」「リスト表示」。
  case tree, list
}
