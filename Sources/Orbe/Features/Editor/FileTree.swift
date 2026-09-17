import AppKit
import Foundation

/// エクスプローラーのツリー——根の実ファイルの、展開集合・一覧・git status・選択・行内の新規入力。
/// 面が画面に見えている間だけ（`isLive`）根のサービスを握り、離すと監視は止まるが一覧と status の
/// キャッシュは保つ（隠れて戻るたびに空から描き直さない）。
///
/// 一覧は展開したディレクトリだけ遅延で取り、監視の通知で変わったパスの親のうち展開中のものを取り直す。
/// status はツリー自身のキャッシュで、サービスの status が非 nil のときだけ上書きする——握り直した直後の
/// 新しいサービスは git が返るまで nil で、それを写すとバッジが毎回消えて戻る。
/// 展開集合は根からの相対パスの集合で、祖先について閉じている（畳めば配下も外れる）。永続しない。
@MainActor @Observable
final class FileTree: RootFilesObserver {
  struct Row: Identifiable, Equatable {
    enum Kind: Equatable {
      case directory(isExpanded: Bool)
      case file(badge: GitStatus.Badge?)
      /// 新規作成の行内入力（ディレクトリならシェブロンの幅を空ける）。
      case input(isDirectory: Bool)
    }
    let id: String
    let depth: Int
    let name: String
    let url: URL
    let kind: Kind
    let isSelected: Bool
  }

  struct NewEntry: Equatable {
    /// 挿す先のディレクトリ（相対パス。根は空）。
    let directory: String
    let isDirectory: Bool
  }

  /// 根（正規形）。
  let root: String
  /// ルート行の題（根の basename を大文字）。
  let rootName: String
  var isRootOpen = true
  private(set) var expanded: Set<String> = []
  /// 相対ディレクトリ → 一覧。空文字が根。
  private(set) var entries: [String: [RootFiles.Entry]] = [:]
  private(set) var status: GitStatus?
  /// 選択表示する行（相対パス）。
  private(set) var selected: String?
  private(set) var newEntry: NewEntry?
  /// 行内入力でファイルを作った（呼び手が開く）。
  @ObservationIgnored var onCreated: ((URL) -> Void)?
  @ObservationIgnored private var files: RootFiles?

  /// 面が見えている間 true。立てると根のサービスを握って展開中を取り直し、下ろすと離す。
  var isLive = false {
    didSet {
      guard isLive != oldValue else { return }
      if isLive {
        let files = RootFiles.shared(for: root)
        self.files = files
        files.addObserver(self)
        reloadAll()
        if let status = files.status { self.status = status }
      } else {
        files?.removeObserver(self)
        files = nil
      }
    }
  }

  init(root: String) {
    self.root = root
    rootName = (root as NSString).lastPathComponent.uppercased()
  }

  // MARK: - 行

  /// 描画用の平坦化（深さ優先。閉じたディレクトリの配下は出ない）。
  var rows: [Row] {
    guard isRootOpen else { return [] }
    var out: [Row] = []
    append(directory: "", depth: 0, into: &out)
    return out
  }

  /// 一覧は名前順（→ `RootFiles.entries`）。面ではディレクトリを先に並べる（見本・VS Code の慣習）。
  private static func directoriesFirst(_ list: [RootFiles.Entry]) -> [RootFiles.Entry] {
    list.filter(\.isDirectory) + list.filter { !$0.isDirectory }
  }

  private func append(directory: String, depth: Int, into out: inout [Row]) {
    if let newEntry, newEntry.directory == directory {
      out.append(
        Row(
          id: "\0new:\(directory)", depth: depth, name: "", url: url(of: directory),
          kind: .input(isDirectory: newEntry.isDirectory), isSelected: false))
    }
    for entry in Self.directoriesFirst(entries[directory] ?? []) {
      let path = Self.join(directory, entry.name)
      if entry.isDirectory {
        let isExpanded = expanded.contains(path)
        out.append(
          Row(
            id: path, depth: depth, name: entry.name, url: entry.url,
            kind: .directory(isExpanded: isExpanded), isSelected: selected == path))
        if isExpanded { append(directory: path, depth: depth + 1, into: &out) }
      } else {
        out.append(
          Row(
            id: path, depth: depth, name: entry.name, url: entry.url,
            kind: .file(badge: status?.badge(of: path)), isSelected: selected == path))
      }
    }
  }

  // MARK: - 開閉・選択

  func toggle(_ directory: String) {
    selected = directory
    if expanded.contains(directory) {
      collapse(directory)
    } else {
      expand(directory)
    }
  }

  /// 根は開いたまま、展開をすべて畳む。
  func collapseAll() {
    expanded = []
    entries = entries.filter { $0.key.isEmpty }
    newEntry = nil
  }

  /// 文書をアクティブにした。根の下なら祖先を開いてその行を選択表示し、根の外なら選択を外す。
  func reveal(_ url: URL) {
    guard let path = relativePath(of: url) else {
      selected = nil
      return
    }
    revealPath(path)
  }

  /// パンくずのディレクトリ。祖先ごと開いて選択表示する。
  func revealDirectory(_ url: URL) {
    guard let path = relativePath(of: url) else { return }
    revealPath(path)
    expand(path)
  }

  private func revealPath(_ path: String) {
    isRootOpen = true
    for ancestor in Self.ancestors(of: path) { expand(ancestor) }
    selected = path
  }

  private func expand(_ directory: String) {
    guard !directory.isEmpty else { return }
    expanded.insert(directory)
    if entries[directory] == nil { reload(directory) }
  }

  private func collapse(_ directory: String) {
    for path in expanded where path == directory || path.hasPrefix(directory + "/") {
      expanded.remove(path)
      entries[path] = nil
    }
  }

  // MARK: - 新規作成

  /// 行内入力を出す。挿す先は、選択がディレクトリならそこ、ファイルならその親、無ければ根。
  func beginNew(isDirectory: Bool) {
    let directory: String
    if let selected {
      directory = self.isDirectory(selected) ? selected : Self.parent(of: selected)
    } else {
      directory = ""
    }
    isRootOpen = true
    for ancestor in Self.ancestors(of: directory) + [directory] { expand(ancestor) }
    newEntry = NewEntry(directory: directory, isDirectory: isDirectory)
  }

  /// 名前を確定して作る。空・`/` 入り・既に在る・作れないは beep して入力に留まる（false）。
  /// 作った変化は監視が拾うが、体感のため親をその場で取り直す。ファイルなら `onCreated` で開く。
  @discardableResult
  func commitNew(_ name: String) -> Bool {
    guard let newEntry, let files else { return false }
    let name = name.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !name.contains("/") else {
      NSSound.beep()
      return false
    }
    let url = url(of: newEntry.directory).appendingPathComponent(
      name, isDirectory: newEntry.isDirectory)
    do {
      if newEntry.isDirectory {
        try files.createDirectory(at: url)
      } else {
        try files.createFile(at: url)
      }
    } catch {
      NSSound.beep()
      return false
    }
    self.newEntry = nil
    reload(newEntry.directory)
    selected = Self.join(newEntry.directory, name)
    if !newEntry.isDirectory { onCreated?(url) }
    return true
  }

  func cancelNew() {
    newEntry = nil
  }

  // MARK: - 一覧

  private func reloadAll() {
    reload("")
    for directory in expanded.sorted(by: { $0.count < $1.count }) where expanded.contains(directory) {
      reload(directory)
    }
  }

  /// 一覧を取り直す。読めなければ空として扱い、展開中なら畳む。取り直した親に無くなった展開中の
  /// ディレクトリは配下ごと畳む。
  private func reload(_ directory: String) {
    guard let files else { return }
    if let list = try? files.entries(of: url(of: directory)) {
      entries[directory] = list
      let present = Set(list.filter(\.isDirectory).map { Self.join(directory, $0.name) })
      for path in expanded where Self.parent(of: path) == directory && !present.contains(path) {
        collapse(path)
      }
    } else if directory.isEmpty {
      entries[directory] = []
    } else {
      collapse(directory)
      entries[directory] = nil
    }
  }

  private func isDirectory(_ path: String) -> Bool {
    entries[Self.parent(of: path)]?.first { $0.name == Self.name(of: path) }?.isDirectory ?? false
  }

  // MARK: - 通知

  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {
    switch change {
    case .scanAll:
      reloadAll()
    case .paths(let paths):
      var directories = Set<String>()
      for path in paths {
        guard let relative = relativePath(ofAbsolute: path) else { continue }
        let parent = Self.parent(of: relative)
        if parent.isEmpty || expanded.contains(parent) { directories.insert(parent) }
      }
      // 浅い順。親の取り直しで畳まれたディレクトリは取り直さない。
      for directory in directories.sorted(by: { $0.count < $1.count })
      where directory.isEmpty || expanded.contains(directory) {
        reload(directory)
      }
    }
  }

  func rootFilesStatusDidChange(_ files: RootFiles) {
    if let status = files.status { self.status = status }
  }

  func rootFiles(_ files: RootFiles, baselineDidChange url: URL) {}

  // MARK: - パス

  private func url(of relativePath: String) -> URL {
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    return relativePath.isEmpty
      ? rootURL : rootURL.appendingPathComponent(relativePath, isDirectory: true)
  }

  private func relativePath(of url: URL) -> String? {
    relativePath(ofAbsolute: GitWorktreeRoot.normalizedPath(url.path))
  }

  private func relativePath(ofAbsolute path: String) -> String? {
    guard path.hasPrefix(root + "/") else { return nil }
    return String(path.dropFirst(root.count + 1))
  }

  private static func join(_ directory: String, _ name: String) -> String {
    directory.isEmpty ? name : directory + "/" + name
  }

  private static func parent(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
  }

  private static func name(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
  }

  /// 根を除く祖先（浅い順）。
  private static func ancestors(of path: String) -> [String] {
    var out: [String] = []
    var current = parent(of: path)
    while !current.isEmpty {
      out.append(current)
      current = parent(of: current)
    }
    return out.reversed()
  }
}
