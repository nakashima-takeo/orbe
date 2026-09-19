import CoreGraphics
import Foundation

/// エディター面のサイドバーの幅と開閉。アプリ全体で 1 つ（タブ・workspace をまたいで同じ）で、app-state に
/// 永続する（タブ単位の面の配置とは別）。幅の下限はここで守り、上限（本体に最低幅が残る）は面の幅を知る
/// pane が決める。
@MainActor @Observable
final class EditorSidebarState {
  private(set) var width: CGFloat
  private(set) var isOpen: Bool
  @ObservationIgnored private let persists: Bool

  init(
    width: CGFloat = Theme.Layout.editorSidebar, isOpen: Bool = true, persists: Bool = false
  ) {
    self.width = Self.clamp(width)
    self.isOpen = isOpen
    self.persists = persists
  }

  /// app-state から起こす（以後の変更は書き戻す）。読めない・範囲外の幅は既定、開閉の欠落は開。
  static func loaded() -> EditorSidebarState {
    let record = AppStatePersistence.load()?.editorSidebar
    let width = record?.width.map { CGFloat($0) }
    return EditorSidebarState(
      width: width.flatMap { $0.isFinite && $0 >= Theme.Layout.editorSidebarMinWidth ? $0 : nil }
        ?? Theme.Layout.editorSidebar,
      isOpen: record?.isOpen ?? true, persists: true)
  }

  /// ドラッグ中の幅（下限だけ守る。書き戻しは `commit`）。
  func setWidth(_ width: CGFloat) {
    let clamped = Self.clamp(width)
    guard clamped != self.width else { return }
    self.width = clamped
  }

  /// ドラッグの終わり。幅を書き戻す。
  func commit() { save() }

  func toggle() {
    isOpen.toggle()
    save()
  }

  private static func clamp(_ width: CGFloat) -> CGFloat {
    guard width.isFinite else { return Theme.Layout.editorSidebar }
    return max(Theme.Layout.editorSidebarMinWidth, width.rounded())
  }

  private func save() {
    guard persists else { return }
    let record = EditorSidebarRecord(width: Double(width), isOpen: isOpen)
    AppStatePersistence.update { $0.editorSidebar = record }
  }
}
