import XCTest

@testable import Orbe

/// status → 2 区分の行と、列の行の組。
///
/// 壊れると何が起きるか。ステージした後に編集したファイルが片方の区分にしか出ない・競合がステージ済みに並んで一括で
/// 解決済みにされる・`git rm --cached` のファイルを解除できない・削除したファイルを「ファイルを開く」で開こうとする・
/// 未追跡を確認なしで捨てる側に数える・git が何も変えない行を一括操作に数える・ボタンの姿が古い行のまま残る・パスの順に
/// 並ばない・レールの件数が行の数と食い違う・区間の表が行とずれて押した行と違う行が開く。
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

  /// すべてステージ・ステージ済みが無いときのコミットに入る行は「変更」の行から、競合と中身だけ変わったサブモジュールを
  /// 除いたもの。すべて破棄に入る行は、競合とサブモジュールのままの変化（コミットが動いたものも）を除いたもの。どれも行と
  /// しては出る。
  func testBulkRowsLeaveOutConflictsAndSubmodulesGitDoesNotChange() {
    let changes = ScmChanges.build(
      GitStatus(
        entries: [
          "a.txt": entry(nil, .modified), "conflict.txt": entry(.unmerged, .unmerged),
          "content": GitStatus.Entry(staged: nil, unstaged: .modified, unstagedSubmodule: .content),
          "moved": GitStatus.Entry(staged: nil, unstaged: .modified, unstagedSubmodule: .commit),
        ], untrackedDirectories: [], branch: nil))
    XCTAssertEqual(changes.changes.map(\.path), ["a.txt", "conflict.txt", "content", "moved"])
    XCTAssertEqual(changes.committable.map(\.path), ["a.txt", "moved"])
    XCTAssertEqual(changes.discardable.map(\.path), ["a.txt"])
  }

  /// 同じ行の枠に、ボタンの押せる・押せないだけが違う行を描き直させると、ボタンの姿が入れ替わる（パス・印は同じなので、
  /// 中身の同一性にボタンの可否が入っていないと前の姿のまま残る）。
  @MainActor
  func testARowRedrawnWithOnlyItsButtonsChangedShowsTheNewButtons() {
    let view = ScmRowView(frame: .zero)
    func enabled(_ submodule: GitStatus.SubmoduleChange?) -> [Bool] {
      let file = ScmChanges.File(
        row: GitStatus.Row(path: "sub", originalPath: nil), badge: .modified,
        existsInWorkingTree: true, isTracked: true, submodule: submodule)
      view.show(.file(.changes, file), language: .en, emoji: nil)
      guard case .file(let content) = view.content else { return [] }
      return content.buttons.map(\.isEnabled)
    }
    XCTAssertEqual(enabled(.content), [true, false, false], "開く・破棄・ステージ")
    XCTAssertEqual(enabled(.commit), [true, false, true])
    XCTAssertEqual(enabled(nil), [true, true, true])
    XCTAssertEqual(enabled(.content), [true, false, false])
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
