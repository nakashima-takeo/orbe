import Foundation

// EditorPaneModel の履歴レール導出（first-parent 連鎖のレーン割当・ref バッジ・実効選択）。

// MARK: - 履歴レール

extension EditorPaneModel {
  var hasChanges: Bool { !files.isEmpty }

  /// HEAD からの first-parent 連鎖（ロード済み範囲）。レーン割当に使う。
  private var firstParentChain: Set<String> {
    var chain: Set<String> = []
    let byOid = Dictionary(commits.map { ($0.oid, $0) }, uniquingKeysWith: { a, _ in a })
    var cursor = commits.first?.oid
    while let oid = cursor, !chain.contains(oid) {
      chain.insert(oid)
      cursor = byOid[oid]?.parents.first
    }
    return chain
  }

  func historyRows() -> [PaneHistoryRow] {
    var rows: [PaneHistoryRow] = []
    if hasChanges {
      let stat = totalStat
      rows.append(
        PaneHistoryRow(
          id: "uncommitted",
          kind: .uncommitted(fileCount: files.count, add: stat.add, del: stat.del),
          lane: 0, dot: .uncommitted, badges: [], unpushed: false))
    }
    let chain = firstParentChain
    let headOid = commits.first?.oid
    for commit in commits {
      let lane = chain.contains(commit.oid) ? 0 : 1
      let unpushed = unpushedOids.contains(commit.oid)
      let dot: PaneHistoryRow.Dot =
        commit.oid == headOid
        ? .head
        : commit.parents.count > 1
          ? .merge
          : unpushed ? .unpushed : .other
      rows.append(
        PaneHistoryRow(
          id: commit.oid, kind: .commit(commit), lane: lane, dot: dot,
          badges: Self.refBadges(of: commit), unpushed: unpushed))
    }
    return rows
  }

  private static func refBadges(of commit: Commit) -> [PaneRefBadge] {
    commit.refs.compactMap { ref in
      if ref.hasPrefix("HEAD -> ") || ref == "HEAD" {
        return PaneRefBadge(style: .head, label: "HEAD")
      }
      if ref.hasPrefix("tag: ") {
        return PaneRefBadge(style: .tag, label: "tag")
      }
      if ref.contains("/") {
        return PaneRefBadge(style: .remote, label: ref)
      }
      // ローカルブランチ（チェックアウト中以外）は装飾過多になるため出さない。
      return nil
    }
  }

  /// 履歴の実効選択（明示選択が無ければ未コミットノード → 先頭コミット）。
  var resolvedHistorySelection: HistorySelection? {
    if let selection = ui.selectedCommit { return selection }
    if hasChanges { return .uncommitted }
    return commits.first.map { .commit($0.oid) }
  }
}

// MARK: - ビューアヘッダ（`‹ i/N ›` ナビ）

extension EditorPaneModel {
  var viewerNav: (index: Int, count: Int)? {
    guard ui.tool == .git, ui.gitTab == .changes, let path = ui.selectedPath,
      let i = files.firstIndex(where: { $0.path == path })
    else { return nil }
    return (i + 1, files.count)
  }

  func selectAdjacentChange(_ delta: Int) {
    guard !files.isEmpty else { return }
    let current = files.firstIndex { $0.path == ui.selectedPath } ?? 0
    let next = (current + delta + files.count) % files.count
    select(path: files[next].path)
  }
}
