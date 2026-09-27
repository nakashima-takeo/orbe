import AppKit
import SwiftUI

/// 結果の列（pane が持つ `SearchResultsView`）を載せる。読む値（行の版・選択・焦点の要求・絵文字の字体）をここで読んで
/// 列へ渡す——値が変わったときだけ列を更新する。
struct SearchResultsList: View {
  let search: ProjectSearch
  let results: SearchResultsView
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    SearchResultsHost(
      results: results, rowsVersion: search.rowsVersion, selection: search.selection,
      wantsFocus: search.focusRequest == .results, emoji: fontResolver.emojiFont)
  }
}

private struct SearchResultsHost: NSViewRepresentable {
  let results: SearchResultsView
  let rowsVersion: Int
  let selection: ProjectSearch.RowID?
  let wantsFocus: Bool
  let emoji: NSFont?

  func makeNSView(context: Context) -> SearchResultsView { results }

  /// 与えられた大きさを埋める（AppKit の自動レイアウトで測らせない。更新のたびに部分木を測る手間がかかる）。
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: SearchResultsView, context: Context)
    -> CGSize?
  {
    proposal.replacingUnspecifiedDimensions()
  }

  func updateNSView(_ results: SearchResultsView, context: Context) {
    results.update(
      rowsVersion: rowsVersion, selection: selection, emoji: emoji, wantsFocus: wantsFocus)
  }
}
