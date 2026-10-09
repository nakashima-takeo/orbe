import Foundation

/// 骨（タブ行・パンくず）の写し。pane が所有し、セッションの変化のたびに
/// `update` で無条件に組み直す。SwiftUI はこの写しだけを読み、`EditorSession` / `EditorDocument` を
/// 直接観測しない。操作は閉包で pane へ戻り、pane がタブ経由でセッションに書く。
@MainActor @Observable
final class EditorShellModel {
  /// タブ行のタブ 1 枚（文書のタブか diff のタブ）。
  struct FileTab: Identifiable, Equatable {
    let id: EditorTab.Key
    let name: String
    /// diff のタブなら、その種類（名前の後に注記を出す）。
    let diffKind: EditorDiff.Kind?
    let chip: FileChip
    let isDirty: Bool
    /// 外部変更で衝突中（ドットを注意の黄で描く）。
    let isConflicted: Bool
    let isActive: Bool
    /// 仮のタブ（名前を斜体、地に斜線）。
    let isPreview: Bool
  }

  struct Crumb: Identifiable, Equatable {
    let id: Int
    let name: String
    /// 根の下ならその祖先の絶対 URL（押すとツリーが開く）。根の外は nil で押せない。
    let directory: URL?
  }

  var tabs: [FileTab] = []
  var activeID: EditorTab.Key?
  /// 焦点のタブが diff のタブか（タブ行の右端に見せ方の切り替えを出す）と、今の見せ方。
  var showsDiffModes = false
  var diffMode = EditorDiff.Mode.inline
  /// 焦点の文書のディレクトリの断片（末尾のファイルは `activeName` / `activeChip`）。
  var crumbs: [Crumb] = []
  var activeName: String?
  var activeChip: FileChip?

  @ObservationIgnored var open: (URL, EditorSession.OpenMode) -> Void = { _, _ in }
  @ObservationIgnored var activate: (EditorTab.Key) -> Void = { _ in }
  /// 仮のタブを普通のタブにする（タブのダブルクリック）。
  @ObservationIgnored var pin: (EditorTab.Key) -> Void = { _ in }
  @ObservationIgnored var requestClose: (EditorTab.Key) -> Void = { _ in }
  /// diff の見せ方を選んだ（タブ行の右端）。
  @ObservationIgnored var selectDiffMode: (EditorDiff.Mode) -> Void = { _ in }
  @ObservationIgnored var revealDirectory: (URL) -> Void = { _ in }
  @ObservationIgnored var createFile: () -> Void = {}
  @ObservationIgnored var createDirectory: () -> Void = {}
  @ObservationIgnored var collapseAll: () -> Void = {}
  /// レールの項目を押した（出しているパネルなら閉じ、別のパネルならそれへ切り替える）。
  @ObservationIgnored var selectPanel: (EditorSidebarState.Panel) -> Void = { _ in }
  /// 行内入力の入力欄が焦点を失った（その世代）。別の view へ移ったなら pane が取り消し、窓へ落ちたなら
  /// pane が預かる。
  @ObservationIgnored var inlineInputLostFocus: (Int) -> Void = { _ in }
  /// 行内入力の行が現れた。焦点を取ってよいか（窓か面自身が持っているときだけ。人が別の view へ移していれば
  /// 奪わない）。
  @ObservationIgnored var inlineInputMayTakeFocus: () -> Bool = { true }

  func update(from session: EditorSession, root: String, diffMode: EditorDiff.Mode) {
    tabs = session.tabs.map { tab in
      let document = tab.document
      var diffKind: EditorDiff.Kind?
      if case .diff(let diff) = tab { diffKind = diff.id.kind }
      return FileTab(
        id: tab.id, name: tab.url.lastPathComponent, diffKind: diffKind,
        chip: FileChip.resolve(tab.url), isDirty: document?.isDirty == true,
        isConflicted: document?.isDiskChanged == true, isActive: tab.id == session.activeID,
        isPreview: tab.id == session.previewID)
    }
    activeID = session.activeID
    self.diffMode = diffMode
    let active = session.activeTab
    activeName = active?.url.lastPathComponent
    activeChip = active.map { FileChip.resolve($0.url) }
    switch active {
    case .diff(let diff)?:
      showsDiffModes = true
      crumbs = Self.crumbs(of: diff.id.url, root: diff.id.root, pressable: diff.id.root == root)
    case .document(let document)?:
      showsDiffModes = false
      crumbs = Self.crumbs(of: document.url, root: root, pressable: true)
    case nil:
      showsDiffModes = false
      crumbs = []
    }
  }

  /// 根の下ならその相対パスの構成要素（`pressable` なら押せる）、根の外なら絶対パスの構成要素（`/` を除く）。末尾の
  /// ファイルは含まない。
  private static func crumbs(of url: URL, root: String, pressable: Bool) -> [Crumb] {
    let path = url.path
    if path.hasPrefix(root + "/") {
      let components = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
      var directory = URL(fileURLWithPath: root, isDirectory: true)
      return components.dropLast().enumerated().map { index, name in
        directory.appendPathComponent(name, isDirectory: true)
        return Crumb(id: index, name: name, directory: pressable ? directory : nil)
      }
    }
    return url.pathComponents.dropFirst().dropLast().enumerated().map { index, name in
      Crumb(id: index, name: name, directory: nil)
    }
  }
}
