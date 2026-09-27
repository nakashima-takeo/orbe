import Foundation
import OrbeEditorCore

/// 結果の平らな行（まとまりの見出しと一致の 2 種）と、選択・折りたたみ・キーボードの移動。行は結果か折りたたみが変わる
/// たびに作り直す（エクスプローラーのツリーと同じ組み方）。↑↓ は選択だけを動かして開かない。
///
/// 選択は位置で持つ（`Anchor`）——行の番号は編集・取り直し・開いた文書への写し替えで一致が落ちるとずれるので、番号で持つと
/// 別の一致を指す。選んだ一致が落ちたら、その位置の直前にいる扱いになり（行は選ばない）、F4 / ⇧F4 はそこから次・前へ進む。
/// 見せる選択（`selection`）は行を作り直すたびに位置から導く。
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

  /// 一致の位置——開いている文書のまとまりは文書の区間の位置（編集に合わせてずらす）、ディスクのまとまりは行と行の中の位置。
  enum MatchPosition: Equatable {
    case offset(Int)
    case line(Int, column: Int)
  }

  /// 選択の実体。
  enum Anchor: Equatable {
    case file(String)
    case match(String, MatchPosition)
    /// 選んでいた一致が落ちた位置の直前。
    case gap(String, MatchPosition)

    var path: String {
      switch self {
      case .file(let path), .match(let path, _), .gap(let path, _): path
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
    reanchor()
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

  // MARK: - 選択

  /// 行を選ぶ（nil で外す）。
  func select(_ id: RowID?) {
    anchor = id.map(anchor(for:))
    selection = id
  }

  private func anchor(for id: RowID) -> Anchor {
    guard let match = id.match, let file = results[id.path], match < file.count else {
      return .file(id.path)
    }
    return .match(id.path, position(ofMatch: match, in: file))
  }

  private func position(ofMatch index: Int, in file: SearchFileMatches) -> MatchPosition {
    if let span = file.document { return .offset(span.ranges[index].location) }
    let match = file.matches[index]
    return .line(match.line, column: match.column.location)
  }

  /// 位置から見せる選択を導く。選んだ一致が無くなっていればその位置の直前にいる扱いにし、畳まれていれば見出しを選ぶ。
  private func reanchor() {
    guard let anchor, let file = results[anchor.path] else {
      anchor = nil
      selection = nil
      return
    }
    switch anchor {
    case .file(let path):
      selection = RowID(path: path, match: nil)
    case .gap:
      selection = nil
    case .match(let path, let position):
      let index = lowerBound(position, in: file)
      guard index < file.count,
        self.position(ofMatch: index, in: file) == position
          || matchesLine(position, index, in: file)
      else {
        self.anchor = .gap(path, position)
        selection = nil
        return
      }
      if collapsed.contains(path) {
        select(RowID(path: path, match: nil))
      } else {
        self.anchor = .match(path, self.position(ofMatch: index, in: file))
        selection = RowID(path: path, match: index)
      }
    }
  }

  /// ディスクの位置（行と行の中の位置）が、開いた文書に写した一致を指しているか（写したまとまりの一致は行と位置を保つ）。
  private func matchesLine(_ position: MatchPosition, _ index: Int, in file: SearchFileMatches)
    -> Bool
  {
    guard case .line(let line, let column) = position else { return false }
    let match = file.matches[index]
    return match.line == line && match.column.location == column
  }

  /// `position` 以降に始まる最初の一致の番号（無ければ件数）。まとまりの一致は位置の順。
  private func lowerBound(_ position: MatchPosition, in file: SearchFileMatches) -> Int {
    var low = 0
    var high = file.count
    while low < high {
      let mid = (low + high) / 2
      if precedes(mid, position, in: file) { low = mid + 1 } else { high = mid }
    }
    return low
  }

  private func precedes(_ index: Int, _ position: MatchPosition, in file: SearchFileMatches)
    -> Bool
  {
    switch position {
    case .offset(let offset):
      guard let span = file.document else { return false }
      return span.ranges[index].location < offset
    case .line(let line, let column):
      let match = file.matches[index]
      return (match.line, match.column.location) < (line, column)
    }
  }

  /// 焦点の文書の編集に選択の位置を追従させる（`results.track` の前に呼ぶ）。選んだ一致が編集に掛かれば、その位置の直前に
  /// いる扱いにする。
  func trackAnchor(_ path: String, _ edit: TextEdit) {
    guard let anchor, anchor.path == path else { return }
    switch anchor {
    case .match(_, .offset(let offset)):
      guard let span = results[path]?.document,
        let range = span.ranges.first(where: { $0.location == offset })
      else { return }
      if let moved = edit.track([range]).first {
        self.anchor = .match(path, .offset(moved.location))
      } else {
        self.anchor = .gap(path, .offset(min(range.location, edit.range.location)))
      }
    case .gap(_, .offset(let offset)):
      let delta = edit.replacementLength - edit.range.length
      let moved =
        offset <= edit.range.location
        ? offset : offset >= NSMaxRange(edit.range) ? offset + delta : edit.range.location
      self.anchor = .gap(path, .offset(moved))
    default:
      return
    }
  }

  // MARK: - マウス

  /// 一致のシングルクリック: 選んで開く（焦点は結果に残る）。見出しのクリック: 開閉。
  func click(_ id: RowID) {
    select(id)
    guard id.match != nil else {
      toggleCollapse(id.path)
      return
    }
    onOpen(id, false)
  }

  /// 一致のダブルクリック: 開いてテキスト面へ焦点を移す。
  func doubleClick(_ id: RowID) {
    guard id.match != nil else { return }
    select(id)
    onOpen(id, true)
  }

  // MARK: - キーボード（結果の列に焦点があるとき）

  /// ⌘↓（入力欄から）: 結果へ。未選択なら先頭を選ぶ。
  func focusResults() {
    guard !rows.isEmpty else { return }
    if selection == nil { select(rows.first?.id) }
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
      select(rows.first?.id)
      return
    }
    select(rows[min(max(0, index + delta), rows.count - 1)].id)
  }

  /// ←: 一致なら親の見出しへ、見出しなら畳む。
  func moveLeft() {
    guard let selection else { return }
    if selection.match != nil {
      select(RowID(path: selection.path, match: nil))
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
      select(RowID(path: selection.path, match: 0))
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
      select(nil)
    }
  }

  /// F4 / ⇧F4: 選択の次・前の一致を選んで開き、テキスト面へ焦点を移す。畳まれたまとまりは開き、端では先頭・末尾へ回る。
  /// 結果が無ければ false。
  @discardableResult
  func step(forward: Bool) -> Bool {
    let files = results.files
    guard !files.isEmpty else { return false }
    let target = neighbor(of: anchor, forward: forward, in: files)
    if collapsed.remove(target.path) != nil { rebuildRows() }
    select(target)
    onOpen(target, true)
    return true
  }

  private func neighbor(
    of anchor: Anchor?, forward: Bool, in files: [SearchFileMatches]
  ) -> RowID {
    let first = RowID(path: files[0].path, match: 0)
    let last = RowID(path: files[files.count - 1].path, match: files[files.count - 1].count - 1)
    guard let anchor, let fileIndex = results.index(of: anchor.path) else {
      return forward ? first : last
    }
    let file = files[fileIndex]
    switch anchor {
    case .file:
      if forward { return RowID(path: file.path, match: 0) }
    case .match(_, let position):
      let next = lowerBound(position, in: file) + (forward ? 1 : -1)
      if next >= 0, next < file.count { return RowID(path: file.path, match: next) }
    case .gap(_, let position):
      let next = lowerBound(position, in: file) - (forward ? 0 : 1)
      if next >= 0, next < file.count { return RowID(path: file.path, match: next) }
    }
    let nextFile = fileIndex + (forward ? 1 : -1)
    guard nextFile >= 0, nextFile < files.count else { return forward ? first : last }
    let neighbor = files[nextFile]
    return RowID(path: neighbor.path, match: forward ? 0 : neighbor.count - 1)
  }
}
