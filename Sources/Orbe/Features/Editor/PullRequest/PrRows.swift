import Foundation
import OrbeEditorCore

/// PR のパネルの列の区分。
enum PrSection: Hashable {
  case commits
  case files
}

/// PR のパネルの列の行の同一性（行の番号がずれても同じ行を指す）。
enum PrRowID: Hashable {
  case section(PrSection)
  /// コミットの行（コミットの ID）。キーでは選ばない。
  case commit(String)
  /// 「古いコミット N 件は表示していません」の行。選ばない。
  case olderCommits
  /// ツリーのフォルダの行（根からの相対パス）。
  case folder(String)
  /// 変更ファイルの行（根からの相対パス）。
  case file(String)

  /// キーと押下で選べる行か（コミットの行と欠けの行は選ばない）。
  var isSelectable: Bool {
    switch self {
    case .section, .folder, .file: true
    case .commit, .olderCommits: false
    }
  }
}

/// PR のパネルの列の行の組——区分「コミット」と「変更ファイル」の見出しと、その下の行。行は PR の中身・ツリーかリストか・
/// 区分とフォルダの開閉だけで決まり、確認済みには依らない（確認済みは描くときに PR ごとの状態から読む——付け外しのたびに
/// 組み直さない）。
struct PrLayout {
  enum Item: Equatable {
    /// 区分の見出し。コミットは総数、変更ファイルはファイル数。
    case section(PrSection, isOpen: Bool, count: Int)
    case olderCommits(Int)
    case commit(GitHubPullRequestContent.Commit)
    /// フォルダ（パス・字下げ・開いているか・配下のファイルのパス）。
    case folder(path: String, depth: Int, isOpen: Bool, files: [String])
    /// ファイル（パス・変化の種類・字下げ）。
    case file(path: String, change: GitHubPullRequestContent.Change, depth: Int)
  }

  static let empty = PrLayout(items: [])

  let items: [Item]
  let index: [PrRowID: Int]
  /// 変更ファイルの区分のファイルの行の番号。
  let fileRows: Range<Int>

  init(items: [Item]) {
    self.items = items
    var index: [PrRowID: Int] = [:]
    var first: Int?
    var last = 0
    for (row, item) in items.enumerated() {
      let id = Self.id(of: item)
      index[id] = row
      if case .file = item {
        first = first ?? row
        last = row + 1
      }
    }
    self.index = index
    fileRows = first.map { $0..<last } ?? items.count..<items.count
  }

  func id(at row: Int) -> PrRowID { Self.id(of: items[row]) }

  private static func id(of item: Item) -> PrRowID {
    switch item {
    case .section(let section, _, _): .section(section)
    case .olderCommits: .olderCommits
    case .commit(let commit): .commit(commit.oid)
    case .folder(let path, _, _, _): .folder(path)
    case .file(let path, _, _): .file(path)
    }
  }

  /// 中身 `content` の行を組む。コミットは古い順（GitHub の PR のコミットの並び）で、総数が読めた件数より多ければ、
  /// 先頭に欠けの行を置く。変更ファイルは、ツリーならエクスプローラーと同じ並び（フォルダが先、名前順。1 つしか子の
  /// 無いフォルダも畳まない）、リストならソース管理の行と同じパス順。
  static func build(
    _ content: GitHubPullRequestContent, asTree: Bool, closed: Set<PrSection>,
    closedFolders: Set<String>
  ) -> PrLayout {
    var items: [Item] = []
    let commitsOpen = !closed.contains(.commits)
    items.append(.section(.commits, isOpen: commitsOpen, count: content.commitCount))
    if commitsOpen {
      let hidden = content.commitCount - content.commits.count
      if hidden > 0 { items.append(.olderCommits(hidden)) }
      items += content.commits.map(Item.commit)
    }
    let filesOpen = !closed.contains(.files)
    items.append(.section(.files, isOpen: filesOpen, count: content.files.count))
    if filesOpen {
      items +=
        asTree
        ? tree(content.files, closedFolders: closedFolders)
        : list(content.files)
    }
    return PrLayout(items: items)
  }

  private static func list(_ files: [GitHubPullRequestContent.File]) -> [Item] {
    files.map { (FileNameOrder.PathKey($0.path), $0) }
      .sorted { FileNameOrder.comparePaths($0.0, $1.0) == .orderedAscending }
      .map { .file(path: $0.1.path, change: $0.1.change, depth: 0) }
  }

  /// フォルダの木の 1 段。
  private final class Folder {
    var folders: [String: Folder] = [:]
    var files: [GitHubPullRequestContent.File] = []
    /// 配下のすべてのファイルのパス。
    var descendants: [String] = []
  }

  private static func tree(_ files: [GitHubPullRequestContent.File], closedFolders: Set<String>)
    -> [Item]
  {
    let root = Folder()
    for file in files {
      var folder = root
      let parts = file.path.split(separator: "/").map(String.init)
      for name in parts.dropLast() {
        folder.descendants.append(file.path)
        let next = folder.folders[name] ?? Folder()
        folder.folders[name] = next
        folder = next
      }
      folder.descendants.append(file.path)
      folder.files.append(file)
    }
    var items: [Item] = []
    append(root, path: "", depth: 0, closedFolders: closedFolders, into: &items)
    return items
  }

  private static func append(
    _ folder: Folder, path: String, depth: Int, closedFolders: Set<String>, into items: inout [Item]
  ) {
    for name in folder.folders.keys.sorted(by: FileNameOrder.precedes) {
      let child = folder.folders[name]!
      let childPath = path.isEmpty ? name : path + "/" + name
      let isOpen = !closedFolders.contains(childPath)
      items.append(
        .folder(path: childPath, depth: depth, isOpen: isOpen, files: child.descendants))
      if isOpen {
        append(child, path: childPath, depth: depth + 1, closedFolders: closedFolders, into: &items)
      }
    }
    let ordered = folder.files.sorted {
      FileNameOrder.precedes(
        ($0.path as NSString).lastPathComponent, ($1.path as NSString).lastPathComponent)
    }
    for file in ordered {
      items.append(.file(path: file.path, change: file.change, depth: depth))
    }
  }
}
