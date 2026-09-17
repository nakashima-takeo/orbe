import Foundation

/// 骨（ファイルタブ行・パンくず・サイドバーの可否）の写し。pane が所有し、セッションの変化のたびに
/// `update` で無条件に組み直す。SwiftUI はこの写しだけを読み、`EditorSession` / `EditorDocument` を
/// 直接観測しない。操作は閉包で pane へ戻り、pane がタブ経由でセッションに書く。
@MainActor @Observable
final class EditorShellModel {
  struct FileTab: Identifiable, Equatable {
    let id: URL
    let name: String
    let chip: FileChip
    let isDirty: Bool
    /// 外部変更で衝突中（ドットを modified 黄で描く）。
    let isConflicted: Bool
    let isActive: Bool
  }

  struct Crumb: Identifiable, Equatable {
    let id: Int
    let name: String
    /// 根の下ならその祖先の絶対 URL（押すとツリーが開く）。根の外は nil で押せない。
    let directory: URL?
  }

  /// サイドバーを開いているか（エクスプローラーが出て、レールに選択印が立つ）。
  var sidebarOpen = true
  var tabs: [FileTab] = []
  var activeID: URL?
  /// 焦点の文書のディレクトリの断片（末尾のファイルは `activeName` / `activeChip`）。
  var crumbs: [Crumb] = []
  var activeName: String?
  var activeChip: FileChip?

  @ObservationIgnored var open: (URL) -> Void = { _ in }
  @ObservationIgnored var activate: (URL) -> Void = { _ in }
  @ObservationIgnored var requestClose: (URL) -> Void = { _ in }
  @ObservationIgnored var revealDirectory: (URL) -> Void = { _ in }
  @ObservationIgnored var createFile: () -> Void = {}
  @ObservationIgnored var createDirectory: () -> Void = {}
  @ObservationIgnored var collapseAll: () -> Void = {}
  /// レールの選択中の項目を押した（サイドバーを閉じる／開く）。
  @ObservationIgnored var toggleSidebar: () -> Void = {}
  /// 行内入力を Enter / Esc で終えた（焦点を面へ戻す）。
  @ObservationIgnored var endInlineInput: () -> Void = {}

  func update(from session: EditorSession, root: String) {
    let active = session.activeDocument
    tabs = session.documents.map { document in
      FileTab(
        id: document.url, name: document.url.lastPathComponent,
        chip: FileChip.resolve(document.url), isDirty: document.isDirty,
        isConflicted: document.isDiskChanged, isActive: document === active)
    }
    activeID = active?.url
    activeName = active?.url.lastPathComponent
    activeChip = active.map { FileChip.resolve($0.url) }
    crumbs = active.map { Self.crumbs(of: $0.url, root: root) } ?? []
  }

  /// 根の下ならその相対パスの構成要素、根の外なら絶対パスの構成要素（`/` を除く）。末尾のファイルは含まない。
  private static func crumbs(of url: URL, root: String) -> [Crumb] {
    let path = url.path
    if path.hasPrefix(root + "/") {
      let components = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
      var directory = URL(fileURLWithPath: root, isDirectory: true)
      return components.dropLast().enumerated().map { index, name in
        directory.appendPathComponent(name, isDirectory: true)
        return Crumb(id: index, name: name, directory: directory)
      }
    }
    return url.pathComponents.dropFirst().dropLast().enumerated().map { index, name in
      Crumb(id: index, name: name, directory: nil)
    }
  }
}
