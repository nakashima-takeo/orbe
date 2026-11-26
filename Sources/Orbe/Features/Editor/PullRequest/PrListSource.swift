import AppKit

/// PR のパネルの列の源——`PrPanel` の行の組を行の列（`RowList`）へ渡し、列の操作をパネルの操作へ届ける。行の確認済みは、
/// 描くたびに PR ごとの状態から読む。
///
/// キーと焦点はソース管理の変更の列と同じ型: ↑↓ は区分の見出し・フォルダ・ファイル行を渡ってファイル行なら PR の diff を
/// 開き（押している間は開かず、離したら開く）、← → は見出しとフォルダの開閉と親・子への移動、Enter はファイル行を開いて
/// 本文へ（見出し・フォルダは開閉）、Esc は選択を外す。ファイル行のシングルクリックは選んで開き、ダブルクリックは開いて
/// 本文へ。見出し・フォルダのクリックは開閉。コミットの行は押せない。
final class PrListSource: RowListSource {
  let panel: PrPanel
  /// 行の文言の言語（列を載せる view が環境から写す）。
  var language = Language.systemDefault

  init(panel: PrPanel) {
    self.panel = panel
  }

  var rows: PrLayout { panel.layout }

  func rowCount(in layout: PrLayout) -> Int { layout.items.count }

  func makeRowView() -> PrRowView { PrRowView(frame: .zero) }

  func show(_ row: Int, of layout: PrLayout, in view: PrRowView, emoji: NSFont?) {
    let item = layout.items[row]
    view.show(item, facts: facts(of: item), language: language, emoji: emoji)
  }

  func row(of selection: PrRowID, in layout: PrLayout) -> Int? { layout.index[selection] }

  func prepareRows(for appearance: NSAppearance) {
    PrRowView.prepare(for: appearance)
  }

  var wantsFocus: Bool { panel.focusRequest }

  func focusRequestDidApply() { panel.focusRequestDidApply() }

  func focusDidChange(_ focused: Bool) { panel.focusDidChange(focused) }

  func perform(_ key: RowListKey, in layout: PrLayout) {
    switch key.action {
    case .up: panel.moveSelection(by: -1, isRepeat: key.isRepeat, in: layout)
    case .down: panel.moveSelection(by: 1, isRepeat: key.isRepeat, in: layout)
    case .left: panel.moveLeft(in: layout)
    case .right: panel.moveRight(isRepeat: key.isRepeat, in: layout)
    case .enter: panel.activateSelection()
    case .escape: panel.select(nil)
    }
  }

  func keyDidRelease() { panel.navigation.keyDidRelease() }

  func click(_ row: Int, in layout: PrLayout) { panel.click(row, in: layout) }

  func doubleClick(_ row: Int, in layout: PrLayout) { panel.doubleClick(row, in: layout) }

  func press(_ row: Int, control: Int, in layout: PrLayout) -> RowListAnchor<PrRowID>? {
    guard let control = PrControl(rawValue: control) else { return nil }
    panel.press(row, control, in: layout)
    return nil
  }

  func select(_ row: Int, in layout: PrLayout) {
    panel.select(layout.id(at: row))
  }

  // MARK: - 行の中身

  /// 行 `item` を描くのに要る、行の組の外の事実（確認済みの数・ツリーで見せているか・ファイルのコメントの数）。
  private func facts(of item: PrLayout.Item) -> PrRowView.Facts {
    let state = panel.state
    let viewed =
      switch item {
      case .section(.files, _, _): state?.viewedCount.viewed ?? 0
      case .folder(_, _, _, let files): panel.viewedCount(of: files)
      case .file(let path, _, _): state?.isViewed(path) == true ? 1 : 0
      case .section(.commits, _, _), .olderCommits, .commit: 0
      }
    let comments = if case .file(let path, _, _) = item { panel.commentCount(of: path) } else { 0 }
    return PrRowView.Facts(viewed: viewed, asTree: panel.asTree, comments: comments)
  }
}
