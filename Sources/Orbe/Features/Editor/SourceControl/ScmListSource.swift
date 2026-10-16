import AppKit

/// ソース管理の列の源——`ScmPanel` の行の組（区分見出し・ファイル行・グラフ）を行の列（`RowList`）へ渡し、列の操作をパネルの
/// 操作へ届ける。
///
/// キーと焦点は検索結果と同じ型: ↑↓ は区分見出しとファイル行だけを渡ってファイル行なら仮のタブで diff を開き（押している間は
/// 開かず、離したら開く）、← → は区分の開閉と見出しへの移動、Enter はファイル行を普通のタブで開いて本文へ（見出しは開閉）、
/// Esc は選択を外す。ファイル行のシングルクリックは選んで仮のタブで開き（焦点は列に残る）、ダブルクリックは普通のタブで開いて
/// 本文へ。見出しのクリックは開閉、「さらに表示」のクリックはグラフの件数を増やす。行の中のボタンは行のクリックにならない。
final class ScmListSource: RowListSource {
  let panel: ScmPanel
  /// 行の文言の言語（pane が窓の環境から配る）。
  var language = Language.systemDefault

  init(panel: ScmPanel) {
    self.panel = panel
  }

  var rowCount: Int { panel.layout.items.count }

  var rowSegments: [RowListSegment] { panel.layout.segments }

  func makeRowView() -> ScmRowView { ScmRowView(frame: .zero) }

  func show(_ row: Int, in view: ScmRowView, emoji: NSFont?) {
    view.show(panel.layout.items[row], language: language, emoji: emoji)
  }

  func row(of selection: ScmRowID) -> Int? { panel.layout.index[selection] }

  func prepareRows(for appearance: NSAppearance) {
    ScmRowView.prepare(for: appearance)
  }

  var wantsFocus: Bool { panel.focusRequest == .list }

  func focusRequestDidApply() { panel.focusRequestDidApply() }

  func focusDidChange(_ focused: Bool) { panel.focusDidChange(.list, focused: focused) }

  func perform(_ key: RowListKey) {
    switch key.action {
    case .up: panel.moveSelection(by: -1, isRepeat: key.isRepeat)
    case .down: panel.moveSelection(by: 1, isRepeat: key.isRepeat)
    case .left: panel.moveLeft()
    case .right: panel.moveRight(isRepeat: key.isRepeat)
    case .enter: panel.activateSelection()
    case .escape: panel.select(nil)
    }
  }

  func keyDidRelease() { panel.navigation.keyDidRelease() }

  func click(_ row: Int) { panel.click(row) }

  func doubleClick(_ row: Int) { panel.doubleClick(row) }

  func press(_ row: Int, control: Int) {
    guard let control = ScmControl(rawValue: control) else { return }
    panel.press(row, control)
  }

  func select(_ row: Int) {
    if let id = panel.layout.id(at: row) { panel.select(id) }
  }
}
