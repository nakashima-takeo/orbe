import Foundation

/// 骨（左の列の中身・タブ行・パンくず）の写し。pane が所有し、セッションの変化のたびに
/// `update` で無条件に組み直す。SwiftUI はこの写しだけを読み、`EditorSession` / `EditorDocument` を
/// 直接観測しない。操作は閉包で pane へ戻り、pane が連経由でセッションに書く。
@MainActor @Observable
final class EditorShellModel {
  /// タブ行のタブ 1 枚（開いている文書 1 つ。識別は文書の実体の URL）。
  struct FileTab: Identifiable, Equatable {
    let id: URL
    let name: String
    let chip: FileChip
    let isDirty: Bool
    /// 外部変更で衝突中（ドットを注意の黄で描く）。
    let isConflicted: Bool
    /// Files の今の文書（画面が Files のときだけ）。
    let isActive: Bool
    /// 仮の文書（名前を斜体、地に斜線）。
    let isPreview: Bool
  }

  /// 本体の PR の diff が見ている PR とパス（タブ行の「確認済みにする」が読み書きする）。
  struct PullRequestFile: Equatable {
    let state: PullRequestState
    let path: String

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.state === rhs.state && lhs.path == rhs.path
    }
  }

  /// 左の列の中身（レールの項目と 1 対 1）。画面と、Files の左の列がエクスプローラーか検索かで決まる。
  enum Panel: CaseIterable {
    case files
    case search
    case sourceControl
    case pullRequest

    /// 画面 `screen` の左の列の中身。Files の画面では `files`（エクスプローラーか検索）。
    init(screen: EditorScreen, files: Panel) {
      switch screen {
      case .files: self = files
      case .changes: self = .sourceControl
      case .pullRequest: self = .pullRequest
      }
    }

    /// この中身を出す画面。
    var screen: EditorScreen {
      switch self {
      case .files, .search: .files
      case .sourceControl: .changes
      case .pullRequest: .pullRequest
      }
    }
  }

  struct Crumb: Identifiable, Equatable {
    let id: Int
    let name: String
    /// 根の下ならその祖先の絶対 URL（押すとツリーが開く）。根の外は nil で押せない。
    let directory: URL?
  }

  var tabs: [FileTab] = []
  /// 左の列に出している中身（pane が画面から決めて写す）。
  var panel = Panel.files
  /// 今の文書の印を付けるタブ（画面が Files のときだけ）。
  var activeID: URL?
  /// 本体が diff か（タブ行の右端に見せ方の切り替えを出す）と、今の見せ方。
  var showsDiffModes = false
  var diffMode = EditorDiff.Mode.inline
  /// 本体が PR の diff なら、その PR とパス。
  var pullRequestFile: PullRequestFile?
  /// 本体のファイル（文書か diff）のディレクトリの断片（末尾のファイルは `activeName` / `activeChip`）。
  var crumbs: [Crumb] = []
  var activeName: String?
  var activeChip: FileChip?

  @ObservationIgnored var open: (URL, EditorSession.OpenMode) -> Void = { _, _ in }
  /// タブを押した（その文書を今の文書にして Files の画面へ移る）。
  @ObservationIgnored var activate: (URL) -> Void = { _ in }
  /// 仮の文書を普通の文書にする（タブのダブルクリック）。
  @ObservationIgnored var pin: (URL) -> Void = { _ in }
  @ObservationIgnored var requestClose: (URL) -> Void = { _ in }
  /// diff の見せ方を選んだ（タブ行の右端）。
  @ObservationIgnored var selectDiffMode: (EditorDiff.Mode) -> Void = { _ in }
  @ObservationIgnored var revealDirectory: (URL) -> Void = { _ in }
  @ObservationIgnored var createFile: () -> Void = {}
  @ObservationIgnored var createDirectory: () -> Void = {}
  @ObservationIgnored var collapseAll: () -> Void = {}
  /// レールの項目を押した（左の列を開いていて、出している中身なら閉じ、そうでなければその画面と中身にして開く）。
  @ObservationIgnored var selectPanel: (Panel) -> Void = { _ in }
  /// 行内入力の入力欄が焦点を失った（その世代）。別の view へ移ったなら pane が取り消し、窓へ落ちたなら
  /// pane が預かる。
  @ObservationIgnored var inlineInputLostFocus: (Int) -> Void = { _ in }
  /// 行内入力の行が現れた。焦点を取ってよいか（窓か面自身が持っているときだけ。人が別の view へ移していれば
  /// 奪わない）。
  @ObservationIgnored var inlineInputMayTakeFocus: () -> Bool = { true }

  func update(from session: EditorSession, root: String, diffMode: EditorDiff.Mode) {
    let filesShown = session.screen == .files
    tabs = session.documents.map { document in
      FileTab(
        id: document.url, name: document.url.lastPathComponent,
        chip: FileChip.resolve(document.url), isDirty: document.isDirty,
        isConflicted: document.isDiskChanged,
        isActive: filesShown && document.url == session.activeURL,
        isPreview: document.url == session.previewURL)
    }
    activeID = filesShown ? session.activeURL : nil
    self.diffMode = diffMode
    switch session.body {
    case .diff(let diff):
      setActive(diff.id.url)
      showsDiffModes = true
      if case .pullRequest(let state) = diff.id.kind {
        pullRequestFile = PullRequestFile(state: state, path: diff.id.path)
      } else {
        pullRequestFile = nil
      }
      crumbs = Self.crumbs(of: diff.id.url, root: diff.id.root, pressable: diff.id.root == root)
    case .document(let document):
      setActive(document.url)
      showsDiffModes = false
      pullRequestFile = nil
      crumbs = Self.crumbs(of: document.url, root: root, pressable: true)
    case .empty:
      setActive(nil)
      showsDiffModes = false
      pullRequestFile = nil
      crumbs = []
    }
  }

  /// パンくずの末尾のファイル。
  private func setActive(_ url: URL?) {
    activeName = url?.lastPathComponent
    activeChip = url.map(FileChip.resolve)
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
