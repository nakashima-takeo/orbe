import AppKit

/// 検索結果の列の源——`ProjectSearch` の平らな行を行の列（`RowList`）へ渡し、列の操作を model の操作へ届ける。
///
/// キー: ↑↓ は選択を動かして一致なら仮のタブで開き（押している間は開かず、離したら開く。→ `ProjectSearch+Open`）、← → は折りたたみと
/// 親子の移動、Enter は普通のタブで開いてテキスト面へ、Esc は止めるか選択を外す。一致のシングルクリックは選んで仮のタブで
/// 開き（焦点は列に残る）、ダブルクリックは普通のタブで開いてテキスト面へ。
final class SearchResultsSource: RowListSource {
  let search: ProjectSearch

  init(search: ProjectSearch) {
    self.search = search
  }

  /// 組は model そのもの（行をその場で畳み替える。列は読み直すまでも今の行の数を上限に問う）。
  var rows: ProjectSearch { search }

  func rowCount(in search: ProjectSearch) -> Int { search.rowCount }

  /// 見出しも一致も同じ高さ（区間 1 つ）。
  func segments(in search: ProjectSearch) -> [RowListSegment] {
    [RowListSegment(start: 0, count: search.rowCount, height: Theme.Layout.editorSearchRow)]
  }

  func makeRowView() -> SearchResultRowView { SearchResultRowView(frame: .zero) }

  func show(_ row: Int, of search: ProjectSearch, in view: SearchResultRowView, emoji: NSFont?) {
    view.show(search.row(at: row), emoji: emoji)
  }

  func row(of selection: ProjectSearch.RowID, in search: ProjectSearch) -> Int? {
    search.rowIndex(of: selection)
  }

  func prepareRows(for appearance: NSAppearance) {
    SearchResultRowView.prepare(for: appearance)
  }

  var wantsFocus: Bool { search.focusRequest == .results }

  func focusRequestDidApply() { search.focusRequestDidApply() }

  func focusDidChange(_ focused: Bool) { search.focusDidChange(.results, focused: focused) }

  func perform(_ key: RowListKey, in search: ProjectSearch) {
    switch key.action {
    case .up: search.moveSelection(by: -1, isRepeat: key.isRepeat)
    case .down: search.moveSelection(by: 1, isRepeat: key.isRepeat)
    case .left: search.moveLeft()
    case .right: search.moveRight(isRepeat: key.isRepeat)
    case .enter: search.activateSelection()
    case .escape: search.escapeInResults()
    }
  }

  func keyDidRelease() { search.navigation.keyDidRelease() }

  func click(_ row: Int, in search: ProjectSearch) { search.click(search.row(at: row).id) }

  func doubleClick(_ row: Int, in search: ProjectSearch) {
    search.doubleClick(search.row(at: row).id)
  }

  func select(_ row: Int, in search: ProjectSearch) { search.select(search.row(at: row).id) }
}
