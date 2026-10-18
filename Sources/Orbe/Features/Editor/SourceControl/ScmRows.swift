import Foundation
import OrbeEditorCore

/// ソース管理の区分。
enum ScmSection: Hashable {
  case staged
  case changes
  case graph
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
    /// 追跡中（破棄は作業ツリーを index の版へ戻す——戻せないので確かめる）。未追跡はゴミ箱へ移す。
    let isTracked: Bool
    /// サブモジュールのままの変化なら、その変わり方。
    let submodule: GitStatus.SubmoduleChange?

    init(
      row: GitStatus.Row, badge: GitStatus.Badge, existsInWorkingTree: Bool, isTracked: Bool,
      submodule: GitStatus.SubmoduleChange? = nil
    ) {
      self.row = row
      self.badge = badge
      self.existsInWorkingTree = existsInWorkingTree
      self.isTracked = isTracked
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
    case .graph: []
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
          (key, File(row: row, badge: .conflicted, existsInWorkingTree: exists, isTracked: true)))
        continue
      }
      if let change = entry.staged {
        staged.append(
          (key, File(row: row, badge: badge(change), existsInWorkingTree: exists, isTracked: true)))
      }
      if let change = entry.unstaged {
        changes.append(
          (
            key,
            File(
              row: row, badge: badge(change), existsInWorkingTree: exists,
              isTracked: change != .untracked,
              submodule: entry.unstagedSubmodule)
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

  private static func badge(_ change: GitStatus.Change) -> GitStatus.Badge {
    switch change {
    case .added, .copied: .added
    case .untracked: .untracked
    case .unmerged: .conflicted
    default: .modified
    }
  }
}

/// ブランチの器の中身。
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

/// 列の行の組——行の列・区間の表・行の同一性の索引。status・グラフ・開閉が変わるたびに裏で 1 つの値として作り、main で
/// 差し替える（行の数が数万でも、main の仕事は差し替えだけ）。
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
    case branch(ScmBranch)
    /// コミット（`isFirst` / `isLast` は縦の線の端）。
    case commit(GitGraphCommit, isFirst: Bool, isLast: Bool)
    case more
  }

  let items: [Item]
  let segments: [RowListSegment]
  /// 区分見出しとファイル行の位置。
  let index: [ScmRowID: Int]
  /// 区分ごとのファイル行の範囲（見出しは含まない）。
  let fileRanges: [ScmSection: Range<Int>]

  static let empty = ScmLayout(items: [], segments: [], index: [:], fileRanges: [:])

  /// 行を作る（裏で呼ぶ）。区分は行が 0 なら見出しごと出さない。グラフはブランチがあれば出す。
  static func build(
    _ changes: ScmChanges, branch: ScmBranch?, graph: GitCommitGraph?,
    collapsed: Set<ScmSection>
  ) -> ScmLayout {
    var items: [Item] = []
    var heights: [CGFloat] = []
    var leadings: [Int: CGFloat] = [:]
    var index: [ScmRowID: Int] = [:]
    var ranges: [ScmSection: Range<Int>] = [:]
    items.reserveCapacity(changes.count + 4)
    heights.reserveCapacity(changes.count + 4)
    let row = Theme.Layout.editorScmRow
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
      heights.append(row)
      let start = items.count
      if isOpen {
        for file in files {
          index[ScmRowID(section: section, path: file.path)] = items.count
          items.append(.file(section, file))
          heights.append(row)
        }
      }
      ranges[section] = start..<items.count
    }
    if let branch {
      let isOpen = !collapsed.contains(.graph)
      index[ScmRowID(section: .graph, path: nil)] = items.count
      leadings[items.count] = Theme.Layout.editorScmGraphGap
      items.append(.header(.graph, count: 0, isOpen: isOpen))
      heights.append(row)
      if isOpen {
        items.append(.branch(branch))
        heights.append(Theme.Layout.editorScmBranch + Theme.Layout.editorScmBranchGap * 2)
        let commits = graph?.commits ?? []
        for (offset, commit) in commits.enumerated() {
          items.append(.commit(commit, isFirst: offset == 0, isLast: offset == commits.count - 1))
          heights.append(row)
        }
        if graph?.hasMore == true {
          items.append(.more)
          heights.append(row)
        }
      }
    }
    return ScmLayout(
      items: items, segments: segments(heights, leadings: leadings), index: index,
      fileRanges: ranges)
  }

  /// 高さの列を、同じ高さの続く区間に畳む。前の余白を持つ行は区間の頭にする。
  private static func segments(
    _ heights: [CGFloat], leadings: [Int: CGFloat]
  ) -> [RowListSegment] {
    var segments: [RowListSegment] = []
    var start = 0
    func close(_ end: Int) {
      segments.append(
        RowListSegment(
          start: start, count: end - start, height: heights[start], leading: leadings[start] ?? 0))
    }
    for (row, height) in heights.enumerated()
    where row > 0 && (height != heights[row - 1] || leadings[row] != nil) {
      close(row)
      start = row
    }
    if start < heights.count { close(heights.count) }
    return segments
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

  /// 行 `row` の同一性（区分見出しとファイル行だけ。ほかは nil）。
  func id(at row: Int) -> ScmRowID? {
    guard row >= 0, row < items.count else { return nil }
    switch items[row] {
    case .header(let section, _, _, _): return ScmRowID(section: section, path: nil)
    case .file(let section, let file): return ScmRowID(section: section, path: file.path)
    default: return nil
    }
  }
}
