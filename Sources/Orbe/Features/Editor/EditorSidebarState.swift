import CoreGraphics
import Foundation

/// エディター面のサイドバーの幅・開閉・出しているパネル（ファイル／検索）。アプリ全体で 1 つ（タブ・workspace を
/// またいで同じ）で、app-state に永続する（タブ単位の面の配置とは別）。幅の下限はここで守り、上限（本体に最低幅が
/// 残る）は面の幅を知る pane が決める。
@MainActor @Observable
final class EditorSidebarState {
  /// サイドバーのパネル（レールの項目と 1 対 1）。
  enum Panel: String, CaseIterable {
    case files
    case search
  }

  private(set) var width: CGFloat
  private(set) var isOpen: Bool
  private(set) var panel: Panel
  @ObservationIgnored private let persists: Bool

  init(
    width: CGFloat = Theme.Layout.editorSidebar, isOpen: Bool = true, panel: Panel = .files,
    persists: Bool = false
  ) {
    self.width = Self.clamp(width)
    self.isOpen = isOpen
    self.panel = panel
    self.persists = persists
  }

  /// app-state から起こす（以後の変更は書き戻す）。読めない・範囲外の幅は既定、開閉の欠落は開、パネルの欠落・未知は
  /// ファイル。
  static func loaded() -> EditorSidebarState {
    let record = AppStatePersistence.load()?.editorSidebar
    let width = record?.width.map { CGFloat($0) }
    return EditorSidebarState(
      width: width.flatMap { $0.isFinite && $0 >= Theme.Layout.editorSidebarMinWidth ? $0 : nil }
        ?? Theme.Layout.editorSidebar,
      isOpen: record?.isOpen ?? true, panel: record?.panel.flatMap(Panel.init) ?? .files,
      persists: true)
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

  private func save() {
    guard persists else { return }
    let record = EditorSidebarRecord(width: Double(width), isOpen: isOpen, panel: panel.rawValue)
    AppStatePersistence.update { $0.editorSidebar = record }
  }
}
