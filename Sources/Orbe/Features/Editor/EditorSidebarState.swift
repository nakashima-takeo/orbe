import CoreGraphics
import Foundation

/// エディター面の左の列の幅・開閉と、ソース管理パネルのグラフの枠の高さと、PR のパネルの変更ファイルをツリーで見せるか。
/// アプリ全体で 1 つ（タブ・workspace をまたいで同じ）で、app-state に永続する。左の列の中身は連の画面で決まり、ここは
/// 持たない。幅と高さの下限はここで守り、上限（本体に最低幅が残る・親に最低限の高さが残る）は大きさを知る pane とパネルが
/// 決める。
@MainActor @Observable
final class EditorSidebarState {
  private(set) var width: CGFloat
  private(set) var isOpen: Bool
  /// ソース管理パネルのグラフの枠の高さ（見出しを含む）。
  private(set) var graphHeight: CGFloat
  /// PR のパネルの変更ファイルをツリーで見せる（偽ならリスト）。
  private(set) var pullRequestFilesAsTree: Bool
  @ObservationIgnored private let persists: Bool

  init(
    width: CGFloat = Theme.Layout.editorSidebar, isOpen: Bool = true,
    graphHeight: CGFloat = Theme.Layout.editorScmGraph, pullRequestFilesAsTree: Bool = true,
    persists: Bool = false
  ) {
    self.width = Self.clamp(width)
    self.isOpen = isOpen
    self.graphHeight = Self.clampGraph(graphHeight)
    self.pullRequestFilesAsTree = pullRequestFilesAsTree
    self.persists = persists
  }

  /// app-state から起こす（以後の変更は書き戻す）。読めない・範囲外の幅と高さは既定、開閉の欠落は開、ツリーかリストかの
  /// 欠落はツリー。
  static func loaded() -> EditorSidebarState {
    let record = AppStatePersistence.load()?.editorSidebar
    let width = record?.width.map { CGFloat($0) }
    let graphHeight = record?.graphHeight.map { CGFloat($0) }
    return EditorSidebarState(
      width: width.flatMap { $0.isFinite && $0 >= Theme.Layout.editorSidebarMinWidth ? $0 : nil }
        ?? Theme.Layout.editorSidebar,
      isOpen: record?.isOpen ?? true,
      graphHeight: graphHeight.flatMap {
        $0.isFinite && $0 >= Theme.Layout.editorScmGraphMin ? $0 : nil
      } ?? Theme.Layout.editorScmGraph,
      pullRequestFilesAsTree: record?.pullRequestFilesAsTree ?? true, persists: true)
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

  /// 開く・閉じる（書き戻す）。
  func setOpen(_ open: Bool) {
    guard open != isOpen else { return }
    isOpen = open
    save()
  }

  /// PR のパネルの変更ファイルをツリーかリストで見せる（書き戻す）。
  func setPullRequestFilesAsTree(_ asTree: Bool) {
    guard asTree != pullRequestFilesAsTree else { return }
    pullRequestFilesAsTree = asTree
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
      width: Double(width), isOpen: isOpen,
      graphHeight: Double(graphHeight), pullRequestFilesAsTree: pullRequestFilesAsTree)
    AppStatePersistence.update { $0.editorSidebar = record }
  }
}
