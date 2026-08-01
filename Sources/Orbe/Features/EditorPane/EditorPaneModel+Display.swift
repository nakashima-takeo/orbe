import Foundation

// EditorPaneModel の表示用導出（スナップショット＋UI 状態 → 各レール・ビューアの行データ）。

// MARK: - 表示行の型

/// ツリーレールの 1 行。
struct PaneTreeRow: Identifiable {
  enum Kind {
    case folder(open: Bool)
    case file(badge: ChangeBadge?)
  }
  let id: String
  let depth: Int
  let name: String
  let path: String
  let kind: Kind
}

/// 変更レールの 1 フォルダグループ。
struct PaneChangeGroup: Identifiable {
  let id: String
  /// 表示名。ディレクトリは docs/ のような形、ルート直下は ./ になる。
  let dir: String
  let open: Bool
  let files: [FileChange]
  let stat: (add: Int, del: Int)
}

/// diff 統合表示の 1 hunk（staged/unstaged の由来フラグ付き）。
struct PaneMergedHunk: Identifiable {
  let id: String
  let staged: Bool
  let untracked: Bool
  let hunkIndex: Int
  let diff: FileDiff
  var hunk: Hunk { diff.hunks[hunkIndex] }

  var stat: (add: Int, del: Int) {
    let lines = hunk.lines
    return (lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count)
  }

  /// `@@ −a,b +c,d @@ heading`（見本の全角マイナス表記）。
  var header: String {
    var text = "@@ −\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
    if !hunk.sectionHeading.isEmpty { text += " \(hunk.sectionHeading)" }
    return text
  }
}

/// ファイル全文表示の 1 行（変更行マーク付き）。
struct PaneFileLine: Identifiable {
  enum Mark {
    case add
    case mod
  }
  let n: Int
  let text: String
  let mark: Mark?
  var id: Int { n }
}

/// 履歴行の ref バッジ（HEAD / origin/... / tag）。
struct PaneRefBadge: Identifiable {
  enum Style {
    case head
    case remote
    case tag
  }
  let style: Style
  let label: String
  var id: String { label }
}

/// 履歴レールの 1 行。
struct PaneHistoryRow: Identifiable {
  enum Kind {
    case uncommitted(fileCount: Int, add: Int, del: Int)
    case commit(Commit)
  }
  enum Dot {
    case uncommitted  // accent＋glow
    case head  // textPrimary 塗り
    case unpushed  // accent 85%
    case merge  // 輪郭（bgBase 地＋accent 枠）
    case other  // idle 塗り
  }
  let id: String
  let kind: Kind
  /// 0 = HEAD の first-parent 連鎖（accent レーン）・1 = それ以外（main レーン）。
  let lane: Int
  let dot: Dot
  let badges: [PaneRefBadge]
  let unpushed: Bool

  var selection: HistorySelection {
    switch kind {
    case .uncommitted: return .uncommitted
    case .commit(let commit): return .commit(commit.oid)
    }
  }
}

// MARK: - 変更集計

extension EditorPaneModel {
  var changedFiles: [FileChange] { files }

  var statusByPath: [String: FileChange] {
    Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
  }

  /// 1 ファイルの ±行数（staged＋unstaged。未追跡は合成 diff から）。
  func diffStat(of path: String) -> (add: Int, del: Int) {
    var add = 0
    var del = 0
    for diff in [stagedDiffs[path], effectiveUnstagedDiff(path)].compactMap({ $0 }) {
      for line in diff.hunks.flatMap(\.lines) {
        if line.kind == .added { add += 1 }
        if line.kind == .removed { del += 1 }
      }
    }
    return (add, del)
  }

  var totalStat: (add: Int, del: Int) {
    files.map { diffStat(of: $0.path) }.reduce((0, 0)) { ($0.0 + $1.add, $0.1 + $1.del) }
  }

  func stageState(of change: FileChange) -> StageState {
    if change.isConflicted { return .none }
    switch (change.staged != nil, change.unstaged != nil) {
    case (true, true): return .partial
    case (true, false): return .staged
    default: return .none
    }
  }

  /// partial ファイルの hunk 進捗（staged hunk 数 / 全 hunk 数）。
  func hunkProgress(of path: String) -> (staged: Int, total: Int)? {
    let staged = stagedDiffs[path]?.hunks.count ?? 0
    let unstaged = effectiveUnstagedDiff(path)?.hunks.count ?? 0
    guard staged > 0, unstaged > 0 else { return nil }
    return (staged, staged + unstaged)
  }

  var stagedFiles: [FileChange] { files.filter { $0.staged != nil && !$0.isConflicted } }

  /// CommitBar の `staged N · +A` 集計。
  var stagedStat: (count: Int, add: Int) {
    let add = stagedDiffs.values.flatMap(\.hunks).flatMap(\.lines)
      .filter { $0.kind == .added }.count
    return (stagedFiles.count, add)
  }
}

// MARK: - ツリーレール

extension EditorPaneModel {
  func treeRows() -> [PaneTreeRow] {
    let status = statusByPath
    var rows: [PaneTreeRow] = []
    func visit(_ nodes: [FileTreeNode], depth: Int) {
      for node in nodes {
        if let children = node.children {
          let open = ui.treeFolderOpen[node.path] ?? false
          rows.append(
            PaneTreeRow(
              id: node.path, depth: depth, name: node.name, path: node.path,
              kind: .folder(open: open)))
          if open { visit(children, depth: depth + 1) }
        } else {
          rows.append(
            PaneTreeRow(
              id: node.path, depth: depth, name: node.name, path: node.path,
              kind: .file(badge: status[node.path].map(ChangeBadge.of))))
        }
      }
    }
    visit(treeNodes, depth: 0)
    return rows
  }

  func toggleTreeFolder(_ path: String) {
    let open = ui.treeFolderOpen[path] ?? false
    ui.treeFolderOpen[path] = !open
  }
}

// MARK: - 変更レール

extension EditorPaneModel {
  func changeGroups() -> [PaneChangeGroup] {
    var byDir: [String: [FileChange]] = [:]
    for file in files {
      byDir[Self.dirName(of: file.path), default: []].append(file)
    }
    return byDir.keys.sorted().map { dir in
      let members = byDir[dir]!
      let stat = members.map { diffStat(of: $0.path) }
        .reduce((0, 0)) { ($0.0 + $1.add, $0.1 + $1.del) }
      return PaneChangeGroup(
        id: dir, dir: dir, open: ui.changesFolderOpen[dir] ?? true, files: members, stat: stat)
    }
  }

  func toggleChangesFolder(_ dir: String) {
    ui.changesFolderOpen[dir] = !(ui.changesFolderOpen[dir] ?? true)
  }

  /// フォルダ行の StageBox 3状態: 配下（conflict 除く）が全 staged→staged・一部→partial・皆無→none。
  func groupStageState(_ group: PaneChangeGroup) -> StageState {
    let states = group.files.filter { !$0.isConflicted }.map { stageState(of: $0) }
    guard !states.isEmpty else { return .none }
    if states.allSatisfy({ $0 == .staged }) { return .staged }
    if states.contains(where: { $0 != .none }) { return .partial }
    return .none
  }
}

// MARK: - ファイル内容（右ビューアのファイル/ソース表示）

extension EditorPaneModel {
  func cachedContent(_ path: String) -> String? {
    if let cached = contentCache[path] { return cached }
    let content = readFile(path)
    contentCache[path] = content
    return content
  }

  /// 実ファイル内容＋変更行マーク。nil = 読めない（バイナリ・削除済み等）。
  /// マークは staged＋unstaged diff の新行番号から導出（hunk 内で removed と対になる added は mod）。
  func fileLines(for path: String) -> [PaneFileLine]? {
    guard let content = cachedContent(path) else { return nil }
    var lines = content.components(separatedBy: "\n")
    if content.hasSuffix("\n") { lines.removeLast() }

    var marks: [Int: PaneFileLine.Mark] = [:]
    for diff in [stagedDiffs[path], effectiveUnstagedDiff(path)].compactMap({ $0 }) {
      for hunk in diff.hunks {
        markChangeBlocks(hunk.lines, into: &marks)
      }
    }
    return lines.enumerated().map { i, text in
      PaneFileLine(n: i + 1, text: text, mark: marks[i + 1])
    }
  }

  /// hunk 内の連続変更ブロックごとに、removed と対になる added を mod・余りを add でマークする。
  private func markChangeBlocks(_ lines: [DiffLine], into marks: inout [Int: PaneFileLine.Mark]) {
    var block: [DiffLine] = []
    func flush() {
      let removed = block.filter { $0.kind == .removed }.count
      var added = 0
      for line in block where line.kind == .added {
        if let n = line.newLine {
          marks[n] = added < removed ? .mod : .add
        }
        added += 1
      }
      block = []
    }
    for line in lines {
      if line.kind == .context {
        flush()
      } else {
        block.append(line)
      }
    }
    flush()
  }
}

// MARK: - diff 統合表示（staged hunk＋unstaged hunk を新行番号順に並置）

extension EditorPaneModel {
  /// 未追跡ファイルは snapshot に diff が無いため、内容から全行 added の合成 diff を使う。
  /// 合成は git 層（バイナリ・巨大物のガード込み）に委譲し、結果をキャッシュする。
  func effectiveUnstagedDiff(_ path: String) -> FileDiff? {
    if let diff = unstagedDiffs[path] { return diff }
    guard statusByPath[path]?.unstaged == .untracked else { return nil }
    if let cached = untrackedDiffCache[path] { return cached }
    guard let diff = makeUntrackedDiff(path) else { return nil }
    untrackedDiffCache[path] = diff
    return diff
  }

  func mergedHunks(for path: String) -> [PaneMergedHunk] {
    let untracked = statusByPath[path]?.unstaged == .untracked
    var hunks: [PaneMergedHunk] = []
    if let staged = stagedDiffs[path] {
      for i in staged.hunks.indices {
        hunks.append(
          PaneMergedHunk(
            id: "S:\(path)@\(staged.hunks[i].newStart)", staged: true, untracked: false,
            hunkIndex: i, diff: staged))
      }
    }
    if let unstaged = effectiveUnstagedDiff(path) {
      for i in unstaged.hunks.indices {
        hunks.append(
          PaneMergedHunk(
            id: "U:\(path)@\(unstaged.hunks[i].newStart)", staged: false, untracked: untracked,
            hunkIndex: i, diff: unstaged))
      }
    }
    // staged（HEAD↔index）と unstaged（index↔worktree）は基準が異なるため新行番号順は近似。
    return hunks.sorted { a, b in
      a.hunk.newStart != b.hunk.newStart
        ? a.hunk.newStart < b.hunk.newStart : (a.staged && !b.staged)
    }
  }

  /// 本文を出さないファイルの note（バイナリ / rename・mode のみ / 空 / conflict）。
  func viewerNote(for path: String) -> String? {
    if statusByPath[path]?.isConflicted == true { return localization.string(.editorNoteConflict) }
    let diffs = [stagedDiffs[path], effectiveUnstagedDiff(path)].compactMap { $0 }
    guard let diff = diffs.first(where: { $0.isBinary }) ?? diffs.first else { return nil }
    if diff.isBinary { return localization.string(.editorNoteBinary) }
    guard diffs.allSatisfy({ $0.hunks.isEmpty }) else { return nil }
    if diff.isRenamed { return localization.string(.editorNoteRenameOnly) }
    if diff.isNew { return localization.string(.editorNoteEmptyFile) }
    return localization.string(.editorNoteModeOnly)
  }
}
