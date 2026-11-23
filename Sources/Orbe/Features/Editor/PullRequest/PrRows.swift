import Foundation

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
  /// 変更ファイルの区分の見出しの下の行（フォルダとファイル）の番号。
  let filesRows: Range<Int>

  init(items: [Item]) {
    self.items = items
    var index: [PrRowID: Int] = [:]
    for (row, item) in items.enumerated() { index[Self.id(of: item)] = row }
    self.index = index
    let start = index[.section(.files)].map { $0 + 1 } ?? items.count
    filesRows = start..<items.count
  }

  func id(at row: Int) -> PrRowID { Self.id(of: items[row]) }

  /// 選ばれていた行 `selection` が、組み直した後のこの組に無い。畳んで隠れたなら、見えている祖先のうち一番深いもの
  /// （畳んだフォルダか区分の見出し）を返す。フォルダの行が消えて配下のファイルが見えている（ツリーからリストへ切り替えた）
  /// なら、配下の最初のファイルを返す——見ていた場所の近くに残す。そのほかで消えたなら（PR の中身から外れた）、前の組
  /// `previous` の変更ファイルの区分の中の同じ位置の行（無ければ最後の行）を返す。区分に行が無ければ nil。
  func reselect(_ selection: PrRowID, from previous: PrLayout, isCollapsed: (PrRowID) -> Bool)
    -> PrRowID?
  {
    if let visible = Self.ancestors(of: selection).first(where: { index[$0] != nil }),
      isCollapsed(visible)
    {
      return visible
    }
    if case .folder(let folder) = selection,
      let first = filesRows.lazy.map(id(at:)).first(where: {
        if case .file(let path) = $0 { path.hasPrefix(folder + "/") } else { false }
      })
    {
      return first
    }
    guard let old = previous.index[selection], previous.filesRows.contains(old),
      !filesRows.isEmpty
    else { return nil }
    let offset = min(old - previous.filesRows.lowerBound, filesRows.count - 1)
    return id(at: filesRows.lowerBound + offset)
  }

  /// 選べる行 `id` の祖先（深い順に、フォルダ、変更ファイルの区分の見出し）。区分の見出しには無い。
  static func ancestors(of id: PrRowID) -> [PrRowID] {
    switch id {
    case .file(let path), .folder(let path):
      var folders: [PrRowID] = []
      var directory = (path as NSString).deletingLastPathComponent
      while !directory.isEmpty {
        folders.append(.folder(directory))
        directory = (directory as NSString).deletingLastPathComponent
      }
      return folders + [.section(.files)]
    case .section, .commit, .olderCommits: return []
    }
  }

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
  /// 先頭に欠けの行を置く。変更ファイルは `files`（その中身の変更ファイルの並び）の、ツリーかリストの並びで置く——ツリーなら
  /// フォルダの行を挟み（1 つしか子の無いフォルダも畳まない）、リストなら字下げ無しに並べる。
  static func build(
    _ content: GitHubPullRequestContent, files: PrChangedFiles, asTree: Bool,
    closed: Set<PrSection>, closedFolders: Set<String>
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
        ? tree(files.tree.files, closedFolders: closedFolders)
        : files.list.files.map { .file(path: $0.path, change: $0.change, depth: 0) }
    }
    return PrLayout(items: items)
  }

  /// ツリーの並び `ordered` に、フォルダの行を挟む。フォルダの配下のファイルは並びの中で続くので、前のファイルとの共通の
  /// フォルダより深いフォルダに入るたびに、その行を置く。閉じたフォルダの中の行は置かない。
  private static func tree(_ ordered: [GitHubPullRequestContent.File], closedFolders: Set<String>)
    -> [Item]
  {
    var items: [Item] = []
    var stack: [String] = []
    /// 閉じたフォルダの中にいる間の、その閉じたフォルダまでの段の数。
    var hiddenFrom: Int?
    for (offset, file) in ordered.enumerated() {
      let folders = file.path.split(separator: "/").dropLast().map(String.init)
      var common = 0
      while common < min(stack.count, folders.count), stack[common] == folders[common] {
        common += 1
      }
      stack.removeLast(stack.count - common)
      if let hidden = hiddenFrom, stack.count < hidden { hiddenFrom = nil }
      while stack.count < folders.count {
        stack.append(folders[stack.count])
        guard hiddenFrom == nil else { continue }
        let path = stack.joined(separator: "/")
        let isOpen = !closedFolders.contains(path)
        items.append(
          .folder(
            path: path, depth: stack.count - 1, isOpen: isOpen,
            files: ordered[offset...].prefix { $0.path.hasPrefix(path + "/") }.map(\.path)))
        if !isOpen { hiddenFrom = stack.count }
      }
      if hiddenFrom == nil {
        items.append(.file(path: file.path, change: file.change, depth: folders.count))
      }
    }
    return items
  }
}
