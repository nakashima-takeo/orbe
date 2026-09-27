import AppKit
import SwiftUI

/// 結果の列（pane が持つ `RowList`）を載せる。読む値（行の版・選択・焦点の要求・絵文字の字体）をここで読んで列へ渡す
/// ——値が変わったときだけ列を更新する。
struct SearchResultsList: View {
  let search: ProjectSearch
  let results: RowList<SearchResultsSource>
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    RowListHost(
      list: results, rowsVersion: search.rowsVersion, selection: search.selection,
      reveal: .nearest, emoji: fontResolver.emojiFont, wantsFocus: search.focusRequest == .results)
  }
}
