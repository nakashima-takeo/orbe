import Foundation
import OrbeEditorCore

/// 結果の平らな行（まとまりの見出しと一致の 2 種）と、選択・折りたたみ・キーボードの移動。行は結果か折りたたみが変わる
/// たびに作り直す（エクスプローラーのツリーと同じ組み方）。↑↓ は選択だけを動かして開かない。
extension ProjectSearch {
  /// 行の同一性。見出しは `match` が nil。
  struct RowID: Hashable {
    let path: String
    let match: Int?
  }

  enum Row: Identifiable {
    case file(SearchFileMatches, isCollapsed: Bool)
    case match(path: String, index: Int, SearchMatch)

    var id: RowID {
      switch self {
      case .file(let file, _): RowID(path: file.path, match: nil)
      case .match(let path, let index, _): RowID(path: path, match: index)
      }
    }
  }

  func rebuildRows() {
    var rows: [Row] = []
    rows.reserveCapacity(results.files.count + results.total)
    var starts: [Int] = []
    starts.reserveCapacity(results.files.count)
    for file in results.files {
      starts.append(rows.count)
      let isCollapsed = collapsed.contains(file.path)
      rows.append(.file(file, isCollapsed: isCollapsed))
      guard !isCollapsed else { continue }
      for (index, match) in file.matches.enumerated() {
        rows.append(.match(path: file.path, index: index, match))
      }
    }
    self.rows = rows
    fileRowStarts = starts
    if let selection, rowIndex(of: selection) == nil {
      self.selection = selection.match == nil ? nil : RowID(path: selection.path, match: nil)
      if let parent = self.selection, rowIndex(of: parent) == nil { self.selection = nil }
    }
  }

  /// 行の位置（まとまりの見出しの位置 ＋ 一致の番号。畳まれた一致・無い行は nil）。
  func rowIndex(of id: RowID) -> Int? {
    guard let file = results.index(of: id.path), file < fileRowStarts.count else { return nil }
    guard let match = id.match else { return fileRowStarts[file] }
    guard !collapsed.contains(id.path), match < results.files[file].count else { return nil }
    return fileRowStarts[file] + 1 + match
  }

  var isAnyExpanded: Bool { results.files.contains { !collapsed.contains($0.path) } }

  func toggleCollapse(_ path: String) {
    if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
    rebuildRows()
  }

  /// ヘッダーの「すべて折りたたむ／すべて展開」。
  func toggleCollapseAll() {
    collapsed = isAnyExpanded ? Set(results.files.map(\.path)) : []
    rebuildRows()
  }

  // MARK: - マウス

  /// 一致のシングルクリック: 選んで開く（焦点は結果に残る）。見出しのクリック: 開閉。
  func click(_ id: RowID) {
    selection = id
    guard id.match != nil else {
      toggleCollapse(id.path)
      return
    }
    onOpen(id, false)
    onGroundChange()
  }

  /// 一致のダブルクリック: 開いてテキスト面へ焦点を移す。
  func doubleClick(_ id: RowID) {
    guard id.match != nil else { return }
    selection = id
    onOpen(id, true)
    onGroundChange()
  }

  // MARK: - キーボード（結果の列に焦点があるとき）

  /// ⌘↓（入力欄から）: 結果へ。未選択なら先頭を選ぶ。
  func focusResults() {
    guard !rows.isEmpty else { return }
    if selection == nil { selection = rows.first?.id }
    requestFocus(.results)
  }

  /// ⌘↑: 先頭（か未選択）なら入力欄へ戻る。戻ったら true。
  func returnToFieldIfAtTop() -> Bool {
    guard selection == nil || selection == rows.first?.id else { return false }
    requestFocus(.field)
    return true
  }

  /// ↑↓: 選択を動かす（開かない）。未選択なら先頭。
  func moveSelection(by delta: Int) {
    guard !rows.isEmpty else { return }
    guard let selection, let index = rowIndex(of: selection) else {
      self.selection = rows.first?.id
      return
    }
    self.selection = rows[min(max(0, index + delta), rows.count - 1)].id
    onGroundChange()
  }

  /// ←: 一致なら親の見出しへ、見出しなら畳む。
  func moveLeft() {
    guard let selection else { return }
    if selection.match != nil {
      self.selection = RowID(path: selection.path, match: nil)
      onGroundChange()
    } else if !collapsed.contains(selection.path) {
      toggleCollapse(selection.path)
    }
  }

  /// →: 畳んだ見出しなら開き、開いた見出しなら最初の一致へ。
  func moveRight() {
    guard let selection, selection.match == nil else { return }
    if collapsed.contains(selection.path) {
      toggleCollapse(selection.path)
    } else {
      self.selection = RowID(path: selection.path, match: 0)
      onGroundChange()
    }
  }

  /// Enter: 見出しなら開閉、一致なら開いてテキスト面へ焦点。
  func activateSelection() {
    guard let selection else { return }
    if selection.match == nil {
      toggleCollapse(selection.path)
    } else {
      onOpen(selection, true)
    }
  }

  /// Esc: 検索中なら止める。そうでなければ選択を外す。
  func escapeInResults() {
    if isSearching {
      stop()
    } else {
      selection = nil
      onGroundChange()
    }
  }

  /// F4 / ⇧F4: 選択の次・前の一致を選んで開き、テキスト面へ焦点を移す。畳まれたまとまりは開き、端では先頭・末尾へ回る。
  /// 結果が無ければ false。
  @discardableResult
  func step(forward: Bool) -> Bool {
    let files = results.files
    guard !files.isEmpty else { return false }
    let target = neighbor(of: selection, forward: forward, in: files)
    if collapsed.remove(target.path) != nil { rebuildRows() }
    selection = target
    onOpen(target, true)
    onGroundChange()
    return true
  }

  private func neighbor(
    of selection: RowID?, forward: Bool, in files: [SearchFileMatches]
  ) -> RowID {
    let first = RowID(path: files[0].path, match: 0)
    let last = RowID(path: files[files.count - 1].path, match: files[files.count - 1].count - 1)
    guard let selection, let fileIndex = results.index(of: selection.path) else {
      return forward ? first : last
    }
    let file = files[fileIndex]
    if let match = selection.match {
      let next = match + (forward ? 1 : -1)
      if next >= 0, next < file.count { return RowID(path: file.path, match: next) }
    } else if forward {
      return RowID(path: file.path, match: 0)
    }
    let nextFile = fileIndex + (forward ? 1 : -1)
    guard nextFile >= 0, nextFile < files.count else { return forward ? first : last }
    let neighbor = files[nextFile]
    return RowID(path: neighbor.path, match: forward ? 0 : neighbor.count - 1)
  }
}
