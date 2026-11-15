import AppKit

/// グラフの列の源——`ScmPanel` のグラフの行の組（ブランチの行・コミット・さらに表示）を行の列（`RowList`）へ渡す。選べる行は
/// 無いので列は焦点を持たず、押しても変更の列の焦点と選択は動かない。押して働くのは「さらに表示」（グラフの件数を増やす）
/// だけ。
final class ScmGraphSource: RowListSource {
  typealias Selection = Never

  let panel: ScmPanel
  /// 行の文言の言語（列を載せる view が環境から写す）。
  var language = Language.systemDefault

  init(panel: ScmPanel) {
    self.panel = panel
  }

  var rows: ScmGraphLayout { panel.graphLayout }

  func rowCount(in layout: ScmGraphLayout) -> Int { layout.items.count }

  func makeRowView() -> ScmGraphRowView { ScmGraphRowView(frame: .zero) }

  func show(_ row: Int, of layout: ScmGraphLayout, in view: ScmGraphRowView, emoji: NSFont?) {
    view.show(layout.items[row], language: language, emoji: emoji)
  }

  func prepareRows(for appearance: NSAppearance) {
    ScmGraphRowView.prepare(for: appearance)
  }

  func click(_ row: Int, in layout: ScmGraphLayout) {
    guard row < layout.items.count, case .more = layout.items[row] else { return }
    panel.showMoreCommits()
  }
}
