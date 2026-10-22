import CoreGraphics
import Foundation

/// エディター面のサイドバーの幅・開閉・出しているパネル（ファイル／検索／ソース管理）と、ソース管理パネルのグラフの枠の
/// 高さ。アプリ全体で 1 つ（タブ・workspace をまたいで同じ）で、app-state に永続する（タブ単位の面の配置とは別）。幅と高さの
/// 下限はここで守り、上限（本体に最低幅が残る・親に最低限の高さが残る）は大きさを知る pane とパネルが決める。
@MainActor @Observable
final class EditorSidebarState {
  /// サイドバーのパネル（レールの項目と 1 対 1）。
  enum Panel: String, CaseIterable {
    case files
    case search
    case sourceControl
  }

  private(set) var width: CGFloat
  private(set) var isOpen: Bool
  private(set) var panel: Panel
  /// ソース管理パネルのグラフの枠の高さ（見出しを含む）。
  private(set) var graphHeight: CGFloat
  @ObservationIgnored private let persists: Bool

  init(
    width: CGFloat = Theme.Layout.editorSidebar, isOpen: Bool = true, panel: Panel = .files,
    graphHeight: CGFloat = Theme.Layout.editorScmGraph, persists: Bool = false
  ) {
    self.width = Self.clamp(width)
    self.isOpen = isOpen
    self.panel = panel
    self.graphHeight = Self.clampGraph(graphHeight)
    self.persists = persists
  }

  /// app-state から起こす（以後の変更は書き戻す）。読めない・範囲外の幅と高さは既定、開閉の欠落は開、パネルの欠落・未知は
  /// ファイル。
  static func loaded() -> EditorSidebarState {
    let record = AppStatePersistence.load()?.editorSidebar
    let width = record?.width.map { CGFloat($0) }
    let graphHeight = record?.graphHeight.map { CGFloat($0) }
    return EditorSidebarState(
      width: width.flatMap { $0.isFinite && $0 >= Theme.Layout.editorSidebarMinWidth ? $0 : nil }
        ?? Theme.Layout.editorSidebar,
      isOpen: record?.isOpen ?? true, panel: record?.panel.flatMap(Panel.init) ?? .files,
      graphHeight: graphHeight.flatMap {
        $0.isFinite && $0 >= Theme.Layout.editorScmGraphMin ? $0 : nil
      } ?? Theme.Layout.editorScmGraph,
      persists: true)
  }

  /// ドラッグ中の幅（下限だけ守る。書き戻しは `commit`）。
  func setWidth(_ width: CGFloat) {
    let clamped = Self.clamp(width)
    guard clamped != self.width else { return }
    self.width = clamped
  }

  /// ドラッグの終わり。幅と高さを書き戻す。
  func commit() { save() }

  /// 境目のドラッグ中のグラフの枠の高さ（下限だけ守る。書き戻しは `commit`）。
  func setGraphHeight(_ height: CGFloat) {
    let clamped = Self.clampGraph(height)
    guard clamped != graphHeight else { return }
    graphHeight = clamped
  }

  /// レールの項目を押した: 出しているパネルなら閉じ、別のパネルならそれへ切り替える（閉じていれば開く）。
  func select(_ panel: Panel) {
    if isOpen, self.panel == panel {
      isOpen = false
    } else {
      self.panel = panel
      isOpen = true
    }
    save()
  }

  /// そのパネルで開く（⌘⇧F）。
  func show(_ panel: Panel) {
    guard !isOpen || self.panel != panel else { return }
    self.panel = panel
    isOpen = true
    save()
  }

  private static func clamp(_ width: CGFloat) -> CGFloat {
    guard width.isFinite else { return Theme.Layout.editorSidebar }
    return max(Theme.Layout.editorSidebarMinWidth, width.rounded())
  }

  private static func clampGraph(_ height: CGFloat) -> CGFloat {
    guard height.isFinite else { return Theme.Layout.editorScmGraph }
    return max(Theme.Layout.editorScmGraphMin, height.rounded())
  }

  private func save() {
    guard persists else { return }
    let record = EditorSidebarRecord(
      width: Double(width), isOpen: isOpen, panel: panel.rawValue,
      graphHeight: Double(graphHeight))
    AppStatePersistence.update { $0.editorSidebar = record }
  }
}
