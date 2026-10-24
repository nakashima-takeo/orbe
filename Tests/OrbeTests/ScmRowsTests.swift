import XCTest

@testable import Orbe

/// status → 2 区分の行と、変更の列・グラフの列の行の組。
///
/// 壊れると何が起きるか。ステージした後に編集したファイルが片方の区分にしか出ない・競合がステージ済みに並んで一括で
/// 解決済みにされる・`git rm --cached` のファイルを解除できない・削除したファイルを「ファイルを開く」で開こうとする・
/// 未追跡を確認なしで捨てる側に数える・戻せない破棄が確認の Return 1 打で走る・git が何も変えない行を一括操作に数える・
/// ボタンの姿が古い行のまま残る・パスの順に並ばない・レールの件数が行の数と食い違う。グラフの列の頭にブランチが出ない・
/// さらに表示が出ない・管理外でも空の枠が出る。
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
    XCTAssertEqual(unstaged["new.txt"]?.discardMovesToTrash, true)
    XCTAssertEqual(unstaged["cached.txt"]?.discardMovesToTrash, true)
    XCTAssertEqual(unstaged["src/a2.swift"]?.discardMovesToTrash, false)
    XCTAssertEqual(unstaged["src/a2.swift"]?.existsInWorkingTree, false)
    XCTAssertEqual(staged["gone.txt"]?.existsInWorkingTree, false)
    XCTAssertEqual(staged["cached.txt"]?.existsInWorkingTree, true)
    XCTAssertEqual(ScmChanges.count(status), changes.count)
  }

  /// 破棄でゴミ箱へ移る行は、作業ツリー側が未追跡か intent-to-add（作業ツリー側の追加・rename）の行。確認が要るのは戻す
  /// パスを含む破棄——ゴミ箱へ移らない行か、元パスを持つ行（intent-to-add の rename の元パスは戻す）。確認の文はゴミ箱へ移る
  /// 行を数える。
  @MainActor
  func testIntentToAddRowsGoToTheTrashAndTheGateCountsThem() {
    let changes = ScmChanges.build(
      GitStatus(
        entries: [
          "intended.txt": entry(nil, .added), "new.txt": entry(nil, .untracked),
          "renamed.txt": entry(nil, .renamed, from: "old.txt"), "a.txt": entry(.added, .modified),
          "gone.txt": entry(.added, .deleted),
        ], untrackedDirectories: [], branch: nil, stagedVersions: [:]))
    let files = Dictionary(uniqueKeysWithValues: changes.changes.map { ($0.path, $0) })
    XCTAssertEqual(
      changes.changes.filter(\.discardMovesToTrash).map(\.path),
      ["intended.txt", "new.txt", "renamed.txt"])
    let pick = { (paths: [String]) in paths.compactMap { files[$0] } }
    XCTAssertFalse(ScmDiscardGate.needsConfirmation(pick(["intended.txt", "new.txt"])))
    XCTAssertTrue(ScmDiscardGate.needsConfirmation(pick(["renamed.txt"])), "元パスは戻す")
    XCTAssertTrue(ScmDiscardGate.needsConfirmation(pick(["intended.txt", "a.txt"])))
    XCTAssertTrue(ScmDiscardGate.needsConfirmation(pick(["gone.txt"])), "消えた intent-to-add は戻す")
    let alert = ScmDiscardGate.alert(pick(["intended.txt", "renamed.txt", "a.txt"]), language: .en)
    XCTAssertTrue(
      alert.informativeText.hasSuffix(" 2 files go to the Trash."), alert.informativeText)
  }

  /// 戻す破棄の確認で、「破棄」は Return では押されず（戻せない側）、Esc はキャンセル。破棄するのは「破棄」を押したときだけ。
  @MainActor
  func testTheDiscardAlertDoesNotConfirmOnReturn() {
    let tracked = ScmChanges.File(
      row: GitStatus.Row(path: "a.txt", originalPath: nil), badge: .modified,
      existsInWorkingTree: true, discardMovesToTrash: false)
    let alert = ScmDiscardGate.alert([tracked], language: .en)
    XCTAssertEqual(alert.buttons.map(\.title), ["Discard", "Cancel"])
    XCTAssertEqual(alert.buttons[0].keyEquivalent, "", "破棄は Return で確定しない")
    XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}", "Esc はキャンセル")
    XCTAssertTrue(ScmDiscardGate.shouldDiscard(.alertFirstButtonReturn))
    XCTAssertFalse(ScmDiscardGate.shouldDiscard(.alertSecondButtonReturn))
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
          "moved": GitStatus.Entry(
            staged: nil, unstaged: .modified, unstagedSubmodule: .commit(dirty: false)),
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
        existsInWorkingTree: true, discardMovesToTrash: false, submodule: submodule)
      view.show(.file(.changes, file), language: .en, emoji: nil)
      guard case .file(let content) = view.content else { return [] }
      return content.buttons.map(\.isEnabled)
    }
    XCTAssertEqual(enabled(.content), [true, false, false], "開く・破棄・ステージ")
    XCTAssertEqual(enabled(.commit(dirty: false)), [true, false, true])
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
    let moved = GitStatus.Entry(
      staged: nil, unstaged: .modified, unstagedSubmodule: .commit(dirty: false))
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
        oid: oid, subject: oid, localBranches: [], remoteBranches: [], isPushed: false)
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
