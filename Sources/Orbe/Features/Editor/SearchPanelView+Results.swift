import AppKit
import SwiftUI

/// 結果の列: まとまりの見出しと一致の平らな行（`SearchResultsTableView`）。読む値（行の版・選択・焦点の要求・絵文字の
/// フォント）をここで読んで表へ渡す——値が変わったときだけ表を更新する。
struct SearchResultsList: View {
  let search: ProjectSearch
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    SearchResultsTable(
      search: search, rowsVersion: search.rowsVersion, selection: search.selection,
      wantsFocus: search.focusRequest == .results, emoji: fontResolver.emojiFont)
  }
}

private struct SearchResultsTable: NSViewRepresentable {
  let search: ProjectSearch
  let rowsVersion: Int
  let selection: ProjectSearch.RowID?
  let wantsFocus: Bool
  let emoji: NSFont?

  func makeCoordinator() -> SearchResultsSource { SearchResultsSource(search: search) }

  func makeNSView(context: Context) -> NSScrollView {
    let source = context.coordinator
    let table = SearchResultsTableView(search: search)
    table.dataSource = source
    table.delegate = source
    table.onWindow = { [weak source] in source?.applyFocusRequest() }
    source.table = table
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.automaticallyAdjustsContentInsets = false
    return scroll
  }

  /// 与えられた大きさを埋める（AppKit の自動レイアウトで測らせない。更新のたびに部分木を測る手間がかかる）。
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize?
  {
    proposal.replacingUnspecifiedDimensions()
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.update(
      rowsVersion: rowsVersion, selection: selection, emoji: emoji, wantsFocus: wantsFocus)
  }
}

/// 表の行の出どころ。行の数・高さ・中身を `ProjectSearch` から番号で引き、表の選択を model の選択に揃える。
@MainActor
final class SearchResultsSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  private let search: ProjectSearch
  weak var table: NSTableView?
  private var rowsVersion: Int?
  /// 最後に写した選択。選択が変わったときだけ、その行が見えるまで送る（列が作られた時点の選択へは送らない）。
  private var selection: ProjectSearch.RowID?
  private var emoji: NSFont?

  init(search: ProjectSearch) {
    self.search = search
    selection = search.selection
  }

  func update(rowsVersion: Int, selection: ProjectSearch.RowID?, emoji: NSFont?, wantsFocus: Bool) {
    guard let table else { return }
    if rowsVersion != self.rowsVersion || emoji !== self.emoji {
      self.rowsVersion = rowsVersion
      self.emoji = emoji
      reloadRows(table)
    }
    let index = selection.flatMap { search.rowIndex(of: $0) }
    if table.selectedRow != index ?? -1 {
      if let index {
        table.selectRowIndexes([index], byExtendingSelection: false)
      } else {
        table.deselectAll(nil)
      }
    }
    if selection != self.selection {
      self.selection = selection
      if let index { table.scrollRowToVisible(index) }
    }
    if wantsFocus {
      // 焦点を移すと入力欄の SwiftUI の焦点も変わるので、この更新の外で当てる。
      DispatchQueue.main.async { [weak self] in self?.applyFocusRequest() }
    }
  }

  /// 行を読み直す。見えている行の view は捨てずに中身だけを差し替える（中身が同じ行は描き直さない）——`reloadData` は
  /// 見えている行を全部作り直して描き直すので、結果が届くたびにその手間がかかる。
  private func reloadRows(_ table: NSTableView) {
    // 行の数と高さの変化は動かさない（既定では高さの変化が動き、動く間は毎フレーム描き直す）。
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0
    NSAnimationContext.current.allowsImplicitAnimation = false
    defer { NSAnimationContext.endGrouping() }
    table.noteNumberOfRowsChanged()
    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<search.rowCount))
    table.enumerateAvailableRowViews { rowView, row in
      guard row < search.rowCount, let rowView = rowView as? SearchResultRowView else { return }
      rowView.show(search.row(at: row), emoji: emoji)
    }
  }

  /// 結果の列へ焦点を入れる要求を当てる（窓に載っていなければ、載ったときにもう一度呼ばれる）。
  func applyFocusRequest() {
    guard search.focusRequest == .results, let table, let window = table.window else { return }
    window.makeFirstResponder(table)
    search.focusRequestDidApply()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    search.rowCount
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    search.isFileRow(row) ? SearchResultRowView.fileHeight : SearchResultRowView.matchHeight
  }

  /// 行の中身は行の view が描くので、列ごとの view は置かない。
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView?
  {
    nil
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let rowView =
      tableView.makeView(withIdentifier: SearchResultRowView.identifier, owner: nil)
      as? SearchResultRowView ?? SearchResultRowView()
    rowView.show(search.row(at: row), emoji: emoji)
    return rowView
  }
}
