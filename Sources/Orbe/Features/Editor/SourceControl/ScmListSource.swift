import AppKit

/// ソース管理の列の源——`ScmPanel` の行の組（区分見出し・ファイル行・グラフ）を行の列（`RowList`）へ渡し、列の操作をパネルの
/// 操作へ届ける。
///
/// キーと焦点は検索結果と同じ型: ↑↓ は区分見出しとファイル行だけを渡ってファイル行なら仮のタブで diff を開き（押している間は
/// 開かず、離したら開く）、← → は区分の開閉と見出しへの移動、Enter はファイル行を普通のタブで開いて本文へ（見出しは開閉）、
/// Esc は選択を外す。ファイル行のシングルクリックは選んで仮のタブで開き（焦点は列に残る）、ダブルクリックは普通のタブで開いて
/// 本文へ。見出しのクリックは開閉、「さらに表示」のクリックはグラフの件数を増やす。行の中のボタンは行のクリックにならない。
/// 行・キー・押下は、列が描いている組で解く（パネルの組が差し替わってから列が読み直すまでの間に押しても、見えている行に当たる）。
final class ScmListSource: RowListSource {
  let panel: ScmPanel
  /// 行の文言の言語（列を載せる view が環境から写す）。
  var language = Language.systemDefault

  init(panel: ScmPanel) {
    self.panel = panel
  }

  /// 組はパネルの今の行の組（差し替えるたびに新しい値）。
  var rows: ScmLayout { panel.layout }

  func rowCount(in layout: ScmLayout) -> Int { layout.items.count }

  func segments(in layout: ScmLayout) -> [RowListSegment] { layout.segments }

  func makeRowView() -> ScmRowView { ScmRowView(frame: .zero) }

  func show(_ row: Int, of layout: ScmLayout, in view: ScmRowView, emoji: NSFont?) {
    view.show(layout.items[row], language: language, emoji: emoji)
  }

  func row(of selection: ScmRowID, in layout: ScmLayout) -> Int? { layout.index[selection] }

  func prepareRows(for appearance: NSAppearance) {
    ScmRowView.prepare(for: appearance)
  }

  var wantsFocus: Bool { panel.focusRequest == .list }

  func focusRequestDidApply() { panel.focusRequestDidApply() }

  func focusDidChange(_ focused: Bool) { panel.focusDidChange(.list, focused: focused) }

  func perform(_ key: RowListKey, in layout: ScmLayout) {
    switch key.action {
    case .up: panel.moveSelection(by: -1, isRepeat: key.isRepeat, in: layout)
    case .down: panel.moveSelection(by: 1, isRepeat: key.isRepeat, in: layout)
    case .left: panel.moveLeft()
    case .right: panel.moveRight(isRepeat: key.isRepeat, in: layout)
    case .enter: panel.activateSelection()
    case .escape: panel.select(nil)
    }
  }

  func keyDidRelease() { panel.navigation.keyDidRelease() }

  func click(_ row: Int, in layout: ScmLayout) { panel.click(row, in: layout) }

  func doubleClick(_ row: Int, in layout: ScmLayout) { panel.doubleClick(row, in: layout) }

  func press(_ row: Int, control: Int, in layout: ScmLayout) -> RowListAnchor<ScmRowID>? {
    guard let control = ScmControl(rawValue: control) else { return nil }
    return panel.press(row, control, in: layout)
  }

  func select(_ row: Int, in layout: ScmLayout) {
    if let id = layout.id(at: row) { panel.select(id) }
  }
}
