import XCTest

@testable import Orbe

/// status → 2 区分の行と、列の行の組。
///
/// 壊れると何が起きるか。ステージした後に編集したファイルが片方の区分にしか出ない・競合がステージ済みに並んで一括で
/// 解決済みにされる・`git rm --cached` のファイルを解除できない・削除したファイルを「ファイルを開く」で開こうとする・
/// 未追跡を確認なしで捨てる側に数える・パスの順に並ばない・レールの件数が行の数と食い違う・区間の表が行とずれて押した行と
/// 違う行が開く。
final class ScmRowsTests: OrbeTestCase {
  private func entry(
    _ staged: GitStatus.Change?, _ unstaged: GitStatus.Change?, from original: String? = nil
  ) -> GitStatus.Entry {
    GitStatus.Entry(staged: staged, unstaged: unstaged, originalPath: original)
  }

  private let status = GitStatus(
    entries: [
      "src/b.swift": GitStatus.Entry(staged: .added, unstaged: .modified),
      "src/a10.swift": GitStatus.Entry(staged: nil, unstaged: .modified),
      "src/a2.swift": GitStatus.Entry(staged: nil, unstaged: .deleted),
      "conflict.txt": GitStatus.Entry(staged: .unmerged, unstaged: .unmerged),
      "cached.txt": GitStatus.Entry(staged: .deleted, unstaged: .untracked),
      "new.txt": GitStatus.Entry(staged: nil, unstaged: .untracked),
      "moved.txt": GitStatus.Entry(staged: .renamed, unstaged: nil, originalPath: "old.txt"),
      "gone.txt": GitStatus.Entry(staged: .deleted, unstaged: nil),
    ], untrackedDirectories: [],
    branch: GitStatus.Branch(name: "main", commit: "abc", upstream: nil))

  func testSectionsBadgesAndOrder() {
    let changes = ScmChanges.build(status)
    XCTAssertEqual(
      changes.staged.map(\.path), ["cached.txt", "gone.txt", "moved.txt", "src/b.swift"])
    XCTAssertEqual(
      changes.changes.map(\.path),
      ["cached.txt", "conflict.txt", "new.txt", "src/a2.swift", "src/a10.swift", "src/b.swift"])
    let staged = Dictionary(uniqueKeysWithValues: changes.staged.map { ($0.path, $0) })
    let unstaged = Dictionary(uniqueKeysWithValues: changes.changes.map { ($0.path, $0) })
    XCTAssertEqual(staged["src/b.swift"]?.badge, .added)
    XCTAssertEqual(unstaged["src/b.swift"]?.badge, .modified)
    XCTAssertEqual(unstaged["conflict.txt"]?.badge, .conflicted)
    XCTAssertEqual(unstaged["new.txt"]?.badge, .untracked)
    XCTAssertEqual(
      staged["moved.txt"]?.row, GitStatus.Row(path: "moved.txt", originalPath: "old.txt"))
    XCTAssertEqual(unstaged["new.txt"]?.isTracked, false)
    XCTAssertEqual(unstaged["cached.txt"]?.isTracked, false)
    XCTAssertEqual(unstaged["src/a2.swift"]?.isTracked, true)
    XCTAssertEqual(unstaged["src/a2.swift"]?.existsInWorkingTree, false)
    XCTAssertEqual(staged["gone.txt"]?.existsInWorkingTree, false)
    XCTAssertEqual(staged["cached.txt"]?.existsInWorkingTree, true)
    XCTAssertEqual(ScmChanges.count(status), changes.count)
  }

  /// 行が 0 の区分は見出しごと出ず、畳んだ区分のファイル行は出ない。区間の表は行を先頭から隙間なく覆う（列が位置から引く
  /// 行と、源が描く行がずれない）。
  func testEmptySectionsAndFoldedFilesAreNotRowsAndSegmentsCoverEveryRow() {
    let changes = ScmChanges(
      staged: [], changes: ScmChanges.build(status).changes.filter { $0.path.hasPrefix("src/") })
    let branch = ScmBranch(status.branch)
    func rows(_ layout: ScmLayout) -> [ScmRowID] {
      layout.items.indices.compactMap(layout.id(at:))
    }
    let header = { (section: ScmSection) in ScmRowID(section: section, path: nil) }
    let layout = ScmLayout.build(changes, branch: branch, graph: nil, collapsed: [])
    XCTAssertEqual(
      rows(layout),
      [header(.changes)]
        + ["src/a2.swift", "src/a10.swift", "src/b.swift"].map {
          ScmRowID(section: .changes, path: $0)
        } + [header(.graph)])
    var next = 0
    for segment in layout.segments {
      XCTAssertEqual(segment.start, next)
      next += segment.count
    }
    XCTAssertEqual(next, layout.items.count)
    let folded = ScmLayout.build(changes, branch: branch, graph: nil, collapsed: [.changes])
    XCTAssertEqual(rows(folded), [header(.changes), header(.graph)])
  }
}
