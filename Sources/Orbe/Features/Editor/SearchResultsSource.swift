import AppKit

/// 検索結果の列の源——`ProjectSearch` の平らな行を行の列（`RowList`）へ渡し、列の操作を model の操作へ届ける。
///
/// キー: ↑↓ は選択だけを動かし（開かない）、← → は折りたたみと親子の移動、Enter は開いてテキスト面へ、Esc は止めるか
/// 選択を外す。一致のシングルクリックは選んで開き（焦点は列に残る）、ダブルクリックは開いてテキスト面へ。
final class SearchResultsSource: RowListSource {
  let search: ProjectSearch

  init(search: ProjectSearch) {
    self.search = search
  }

  var rowCount: Int { search.rowCount }

  func makeRowView() -> SearchResultRowView { SearchResultRowView(frame: .zero) }

  func show(_ row: Int, in view: SearchResultRowView, emoji: NSFont?) {
    view.show(search.row(at: row), emoji: emoji)
  }

  func row(of selection: ProjectSearch.RowID) -> Int? { search.rowIndex(of: selection) }

  func prepareRows(for appearance: NSAppearance) {
    SearchResultRowView.prepare(for: appearance)
  }

  var wantsFocus: Bool { search.focusRequest == .results }

  func focusRequestDidApply() { search.focusRequestDidApply() }

  func focusDidChange(_ focused: Bool) { search.focusDidChange(.results, focused: focused) }

  func perform(_ key: RowListKey) {
    switch key {
    case .up: search.moveSelection(by: -1)
    case .down: search.moveSelection(by: 1)
    case .left: search.moveLeft()
    case .right: search.moveRight()
    case .enter: search.activateSelection()
    case .escape: search.escapeInResults()
    }
  }

  func click(_ row: Int) { search.click(search.row(at: row).id) }

  func doubleClick(_ row: Int) { search.doubleClick(search.row(at: row).id) }

  func select(_ row: Int) { search.select(search.row(at: row).id) }
}
