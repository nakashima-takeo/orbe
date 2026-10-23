import XCTest

@testable import Orbe

/// status → 2 区分の行と、変更の列・グラフの列の行の組。
///
/// 壊れると何が起きるか。ステージした後に編集したファイルが片方の区分にしか出ない・競合がステージ済みに並んで一括で
/// 解決済みにされる・`git rm --cached` のファイルを解除できない・削除したファイルを「ファイルを開く」で開こうとする・
/// 未追跡を確認なしで捨てる側に数える・git が何も変えない行を一括操作に数える・ボタンの姿が古い行のまま残る・パスの順に
/// 並ばない・レールの件数が行の数と食い違う。グラフの列の頭にブランチが出ない・さらに表示が出ない・管理外でも空の枠が出る。
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
      "src/a2.swift": GitStatus.Entry(staged: nil, unstaged: .deleted, workingTree: .absent),
      "conflict.txt": GitStatus.Entry(staged: .unmerged, unstaged: .unmerged),
      "cached.txt": GitStatus.Entry(staged: .deleted, unstaged: .untracked),
      "new.txt": GitStatus.Entry(staged: nil, unstaged: .untracked),
      "moved.txt": GitStatus.Entry(staged: .renamed, unstaged: nil, originalPath: "old.txt"),
      "gone.txt": GitStatus.Entry(staged: .deleted, unstaged: nil, workingTree: .absent),
    ], untrackedDirectories: [],
    branch: GitStatus.Branch(name: "main", commit: "abc", upstream: nil), stagedVersions: [:])

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
    XCTAssertEqual(unstaged["src/a2.swift"]?.opensAsFile, false)
    XCTAssertEqual(staged["gone.txt"]?.opensAsFile, false)
    XCTAssertEqual(staged["cached.txt"]?.opensAsFile, true)
    XCTAssertEqual(ScmChanges.count(status), changes.count)
  }

  /// 「ファイルを開く」が押せるのは、作業ツリーにファイルとして在る行だけ——作業ツリーに無い競合（`DD`・競合中に消した
  /// `UU`）とサブモジュールの行（ステージ済みも変更も）は開けない。ファイルに置き換えたサブモジュールと、index から外して
  /// 作業ツリーに残したファイルは開ける。
  func testOnlyRowsThatAreFilesInTheWorkingTreeOpenAsFiles() {
    let zero = String(repeating: "0", count: 40)
    func line(_ xy: String, _ sub: String, _ modes: String, _ path: String) -> String {
      "1 \(xy) \(sub) \(modes) \(zero) \(zero) \(path)"
    }
    func conflict(_ xy: String, _ modes: String, _ path: String) -> String {
      "u \(xy) N... \(modes) \(zero) \(zero) \(zero) \(path)"
    }
    let tokens = [
      conflict("DD", "100644 000000 000000 000000", "both-deleted.txt"),
      conflict("UU", "100644 100644 100644 000000", "deleted-in-conflict.txt"),
      conflict("UU", "100644 100644 100644 100644", "conflict.txt"),
      line("A.", "S...", "000000 160000 160000", "added-sub"),
      line(".M", "SC..", "160000 160000 160000", "moved-sub"),
      line("MT", "S...", "160000 160000 100644", "sub-as-file"),
      line("D.", "N...", "100644 000000 000000", "cached.txt"), "? cached.txt",
    ]
    let status = GitStatus.parse(Data((tokens.joined(separator: "\u{0}") + "\u{0}").utf8))
    let changes = ScmChanges.build(status)
    let opens = { (files: [ScmChanges.File]) in
      Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.opensAsFile) })
    }
    XCTAssertEqual(
      opens(changes.changes),
      [
        "both-deleted.txt": false, "deleted-in-conflict.txt": false, "conflict.txt": true,
        "moved-sub": false, "sub-as-file": true, "cached.txt": true,
      ])
    XCTAssertEqual(
      opens(changes.staged), ["added-sub": false, "sub-as-file": true, "cached.txt": true])
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
        ], untrackedDirectories: [], branch: nil, stagedVersions: [:]))
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
        opensAsFile: true, isTracked: true, submodule: submodule)
      view.show(.file(.changes, file), language: .en, emoji: nil)
      guard case .file(let content) = view.content else { return [] }
      return content.buttons.map(\.isEnabled)
    }
    XCTAssertEqual(enabled(.content), [true, false, false], "開く・破棄・ステージ")
    XCTAssertEqual(enabled(.commit), [true, false, true])
    XCTAssertEqual(enabled(nil), [true, true, true])
    XCTAssertEqual(enabled(.content), [true, false, false])
  }

  /// 「変更」の見出しのすべてステージ・すべて破棄は、入る行が無ければ押せない姿になる（競合とサブモジュールの行しか無い
  /// とき、押せる姿のままだと何も起きない）。
  @MainActor
  func testBulkButtonsOfTheChangesHeaderAreDisabledWithoutRowsToTake() {
    let view = ScmRowView(frame: .zero)
    func enabled(_ entries: [String: GitStatus.Entry]) -> [Bool] {
      let changes = ScmChanges.build(
        GitStatus(entries: entries, untrackedDirectories: [], branch: nil, stagedVersions: [:]))
      let layout = ScmLayout.build(changes, collapsed: [])
      guard let row = layout.index[ScmRowID(section: .changes, path: nil)] else { return [] }
      view.show(layout.items[row], language: .en, emoji: nil)
      guard case .header(let header) = view.content else { return [] }
      return header.buttons.map(\.isEnabled)
    }
    let conflict = entry(.unmerged, .unmerged)
    let content = GitStatus.Entry(staged: nil, unstaged: .modified, unstagedSubmodule: .content)
    let moved = GitStatus.Entry(staged: nil, unstaged: .modified, unstagedSubmodule: .commit)
    XCTAssertEqual(enabled(["c.txt": conflict, "sub": content]), [false, false], "すべて破棄・すべてステージ")
    XCTAssertEqual(enabled(["c.txt": conflict, "sub": moved]), [false, true])
    XCTAssertEqual(enabled(["c.txt": conflict, "a.txt": entry(nil, .modified)]), [true, true])
  }

  /// 変更の列は子の見出しとファイル行だけ。行が 0 の区分は見出しごと出ず、畳んだ区分のファイル行は出ない。
  func testEmptySectionsAndFoldedFilesAreNotRows() {
    let changes = ScmChanges(
      staged: [], changes: ScmChanges.build(status).changes.filter { $0.path.hasPrefix("src/") },
      head: nil, stagedVersions: [:])
    func rows(_ layout: ScmLayout) -> [ScmRowID?] {
      layout.items.indices.map(layout.id(at:))
    }
    let header = ScmRowID(section: .changes, path: nil)
    let layout = ScmLayout.build(changes, collapsed: [])
    XCTAssertEqual(
      rows(layout),
      [header]
        + ["src/a2.swift", "src/a10.swift", "src/b.swift"].map {
          ScmRowID(section: .changes, path: $0)
        })
    XCTAssertEqual(rows(ScmLayout.build(changes, collapsed: [.changes])), [header])
  }

  /// グラフの列は頭にブランチの行、コミット（縦の線の端は最初と最後）、続きがあれば「さらに表示」。ブランチが無ければ空。
  func testTheGraphRowsStartWithTheBranchAndEndWithMoreOnlyWhenThereIsMore() throws {
    let branch = ScmBranch(status.branch)
    func commit(_ oid: String) -> GitGraphCommit {
      GitGraphCommit(
        oid: oid, parents: [], subject: oid, localBranches: [], remoteBranches: [], isPushed: false)
    }
    let commits = [commit("c2"), commit("c1")]
    let layout = ScmGraphLayout.build(
      branch: branch, graph: GitCommitGraph(commits: commits, hasMore: true))
    XCTAssertEqual(
      layout.items,
      [
        .branch(try XCTUnwrap(branch)),
        .commit(commits[0], isFirst: true, isLast: false),
        .commit(commits[1], isFirst: false, isLast: true), .more,
      ])
    XCTAssertEqual(
      ScmGraphLayout.build(branch: branch, graph: nil).items, [.branch(try XCTUnwrap(branch))],
      "読む前もブランチの行は出る")
    XCTAssertEqual(
      ScmGraphLayout.build(branch: nil, graph: GitCommitGraph(commits: commits, hasMore: false)),
      .empty)
  }
}
