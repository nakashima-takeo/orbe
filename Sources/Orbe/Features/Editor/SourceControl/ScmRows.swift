import Foundation
import OrbeEditorCore

/// ソース管理の子の区分（親「ソース管理」の中）。
enum ScmSection: Hashable {
  case staged
  case changes
}

/// 列の行の同一性（行の番号がずれても同じ行を指す）。区分見出しは `path` が nil。
struct ScmRowID: Hashable {
  let section: ScmSection
  let path: String?
}

/// status の 2 区分——「ステージされている変更」（index 側の変化。競合は含めない）と「変更」（作業ツリー側の変化と競合）。
/// 同じファイルが両方に出ることがある（ステージした後に編集した・`git rm --cached`）。並びはパス順（`FileNameOrder` の
/// パスの比べ方。区切りごとに名前を比べ、同じ階層ではファイルが先）。status は数万エントリになりうるので、裏で作る。
struct ScmChanges {
  struct File: Equatable {
    /// 操作に渡す行（rename なら元パスも）。
    let row: GitStatus.Row
    /// その区分の変化の印（追加 A・未追跡 U・競合 C、ほか M）。
    let badge: GitStatus.Badge
    /// 作業ツリーに在る（「ファイルを開く」が押せる）。
    let existsInWorkingTree: Bool
    /// 「変更」の行の破棄で、行のパスがゴミ箱へ移る（戻せる）。偽なら index の版へ戻す（戻せないので確かめる）。規則は
    /// `GitStatus.Entry.discardMovesToTrash`（`GitRepo.discard` と同じ）から写す。rename の元パスは戻す側。
    let discardMovesToTrash: Bool
    /// サブモジュールのままの変化なら、その変わり方。
    let submodule: GitStatus.SubmoduleChange?

    init(
      row: GitStatus.Row, badge: GitStatus.Badge, existsInWorkingTree: Bool,
      discardMovesToTrash: Bool, submodule: GitStatus.SubmoduleChange? = nil
    ) {
      self.row = row
      self.badge = badge
      self.existsInWorkingTree = existsInWorkingTree
      self.discardMovesToTrash = discardMovesToTrash
      self.submodule = submodule
    }

    var path: String { row.path }
    var isConflicted: Bool { badge == .conflicted }
    /// 「変更」の行のステージで git が何か変える（中身だけ変わったサブモジュールは add しても何も変わらない）。
    var canStage: Bool { submodule != .content }
    /// 「変更」の行の破棄で git が何か変える（競合は破棄しない。サブモジュールのままの変化は restore しても何も変わらない）。
    var canDiscard: Bool { !isConflicted && submodule == nil }
  }

  let staged: [File]
  let changes: [File]
  /// 「変更」のうち、すべてステージ・ステージ済みが無いときのコミットに入る行——競合と、ステージできない行を除く。
  let committable: [File]
  /// 「変更」のうち、すべて破棄に入る行（破棄できる行）。
  let discardable: [File]
  /// 2 区分を作った status の HEAD（nil = 初回コミット前）。ステージ済みの区分はこれとの差。
  let head: String?
  /// ステージ済みの区分が見せている index の版（rename は元パスも。→ `GitStatus.stagedVersions`）。
  let stagedVersions: [String: GitStatus.IndexVersion]

  init(
    staged: [File], changes: [File], head: String?,
    stagedVersions: [String: GitStatus.IndexVersion]
  ) {
    self.staged = staged
    self.changes = changes
    self.head = head
    self.stagedVersions = stagedVersions
    committable = changes.filter { !$0.isConflicted && $0.canStage }
    discardable = changes.filter(\.canDiscard)
  }

  static let empty = ScmChanges(staged: [], changes: [], head: nil, stagedVersions: [:])

  /// 件数（ステージ済み＋変更の行）。
  var count: Int { staged.count + changes.count }

  func files(in section: ScmSection) -> [File] {
    switch section {
    case .staged: staged
    case .changes: changes
    }
  }

  /// status から 2 区分を作る（裏で呼ぶ）。
  static func build(_ status: GitStatus) -> ScmChanges {
    var staged: [(FileNameOrder.PathKey, File)] = []
    var changes: [(FileNameOrder.PathKey, File)] = []
    for (path, entry) in status.entries {
      let row = GitStatus.Row(path: path, originalPath: entry.originalPath)
      let exists =
        !(entry.unstaged == .deleted || (entry.staged == .deleted && entry.unstaged == nil))
      let key = FileNameOrder.PathKey(path)
      if entry.isConflicted {
        changes.append(
          (
            key,
            File(
              row: row, badge: .conflicted, existsInWorkingTree: exists,
              discardMovesToTrash: false)
          ))
        continue
      }
      if let change = entry.staged {
        staged.append(
          (
            key,
            File(
              row: row, badge: .init(change), existsInWorkingTree: exists,
              discardMovesToTrash: false)
          ))
      }
      if let change = entry.unstaged {
        changes.append(
          (
            key,
            File(
              row: row, badge: .init(change), existsInWorkingTree: exists,
              discardMovesToTrash: entry.discardMovesToTrash, submodule: entry.unstagedSubmodule)
          ))
      }
    }
    let ordered = { (files: [(FileNameOrder.PathKey, File)]) in
      files.sorted { FileNameOrder.comparePaths($0.0, $1.0) == .orderedAscending }.map(\.1)
    }
    return ScmChanges(
      staged: ordered(staged), changes: ordered(changes), head: status.branch?.commit,
      stagedVersions: status.stagedVersions)
  }

  /// 件数だけ（パネルを出していない間。並べ替えない）。
  static func count(_ status: GitStatus) -> Int {
    status.entries.values.reduce(0) { count, entry in
      if entry.isConflicted { return count + 1 }
      return count + (entry.staged == nil ? 0 : 1) + (entry.unstaged == nil ? 0 : 1)
    }
  }

}

/// グラフの先頭のブランチの行の中身。
struct ScmBranch: Equatable {
  /// ブランチ名（detached なら HEAD の短い sha。初回コミット前の detached は無い）。
  let label: String
  /// 先行/遅れ（upstream があり数が分かるときだけ）。
  let divergence: GitStatus.Divergence?

  init?(_ branch: GitStatus.Branch?) {
    guard let branch else { return nil }
    if let name = branch.name {
      label = name
    } else if let commit = branch.commit {
      label = String(commit.prefix(7))
    } else {
      return nil
    }
    divergence = branch.upstream?.divergence
  }
}

/// 変更の列の行の組——行の列・行の同一性の索引。status・開閉が変わるたびに裏で 1 つの値として作り、main で差し替える
/// （行の数が数万でも、main の仕事は差し替えだけ）。
struct ScmLayout {
  /// 「変更」の見出しのすべてステージ・すべて破棄に入る行があるか。
  struct Bulk {
    let canStageAll: Bool
    let canDiscardAll: Bool

    static let none = Bulk(canStageAll: false, canDiscardAll: false)
  }

  enum Item {
    case header(ScmSection, count: Int, isOpen: Bool, bulk: Bulk = .none)
    case file(ScmSection, ScmChanges.File)
  }

  let items: [Item]
  /// 区分見出しとファイル行の位置。
  let index: [ScmRowID: Int]
  /// 区分ごとのファイル行の範囲（見出しは含まない）。
  let fileRanges: [ScmSection: Range<Int>]

  static let empty = ScmLayout(items: [], index: [:], fileRanges: [:])

  /// 行を作る（裏で呼ぶ）。区分は行が 0 なら見出しごと出さない。
  static func build(_ changes: ScmChanges, collapsed: Set<ScmSection>) -> ScmLayout {
    var items: [Item] = []
    var index: [ScmRowID: Int] = [:]
    var ranges: [ScmSection: Range<Int>] = [:]
    items.reserveCapacity(changes.count + 2)
    for section in [ScmSection.staged, .changes] {
      let files = changes.files(in: section)
      guard !files.isEmpty else { continue }
      let isOpen = !collapsed.contains(section)
      index[ScmRowID(section: section, path: nil)] = items.count
      let bulk =
        section == .changes
        ? Bulk(
          canStageAll: !changes.committable.isEmpty, canDiscardAll: !changes.discardable.isEmpty)
        : .none
      items.append(.header(section, count: files.count, isOpen: isOpen, bulk: bulk))
      let start = items.count
      if isOpen {
        for file in files {
          index[ScmRowID(section: section, path: file.path)] = items.count
          items.append(.file(section, file))
        }
      }
      ranges[section] = start..<items.count
    }
    return ScmLayout(items: items, index: index, fileRanges: ranges)
  }

  /// 区分 `section` のファイル行のうち `offset` 番目の位置に来る行（範囲の外なら最後の行）。`skipped` の行は数えない——その行が
  /// 抜けた後の並びで引く。区分に行が無ければ nil。選んだ行・押した行が区分から抜けたときに、次に指す行（同じ区分のその位置の
  /// 行、無ければ前の行）。
  func fileID(in section: ScmSection, at offset: Int, skipping skipped: Int? = nil) -> ScmRowID? {
    guard let range = fileRanges[section] else { return nil }
    let skips = skipped.map(range.contains) ?? false
    let count = range.count - (skips ? 1 : 0)
    guard count > 0 else { return nil }
    var row = range.lowerBound + min(max(0, offset), count - 1)
    if skips, let skipped, row >= skipped { row += 1 }
    return id(at: row)
  }

  /// ファイル行 `row` の部品を押した後に留める行（押した行と、それが抜けた後に同じ位置へ来る行。区分に他の行が無ければ
  /// 後継なし——押し続けの守りのために錨は返す）。
  func anchor(pressing row: Int, in section: ScmSection) -> RowListAnchor<ScmRowID>? {
    guard let pressed = id(at: row), let range = fileRanges[section] else { return nil }
    return RowListAnchor(
      pressed: pressed,
      successor: fileID(in: section, at: row - range.lowerBound, skipping: row))
  }

  /// 行 `row` の同一性（範囲の外なら nil）。
  func id(at row: Int) -> ScmRowID? {
    guard row >= 0, row < items.count else { return nil }
    switch items[row] {
    case .header(let section, _, _, _): return ScmRowID(section: section, path: nil)
    case .file(let section, let file): return ScmRowID(section: section, path: file.path)
    }
  }
}

/// グラフの列の行の組——先頭のブランチの行・コミット・さらに表示。ブランチが無ければ空（グラフの枠を出さない）。高々数百行
/// なので、グラフかブランチが変わった時点で main で作る（変更の組の裏の組み立てには相乗りしない——グラフだけの変化で
/// 数万行の変更の組を作り直さない）。
struct ScmGraphLayout: Equatable {
  enum Item: Equatable {
    case branch(ScmBranch)
    /// コミット（`isFirst` / `isLast` は縦の線の端）。
    case commit(GitGraphCommit, isFirst: Bool, isLast: Bool)
    case more
  }

  let items: [Item]

  static let empty = ScmGraphLayout(items: [])

  static func build(branch: ScmBranch?, graph: GitCommitGraph?) -> ScmGraphLayout {
    guard let branch else { return .empty }
    let commits = graph?.commits ?? []
    var items: [Item] = [.branch(branch)]
    for (offset, commit) in commits.enumerated() {
      items.append(.commit(commit, isFirst: offset == 0, isLast: offset == commits.count - 1))
    }
    if graph?.hasMore == true { items.append(.more) }
    return ScmGraphLayout(items: items)
  }
}
