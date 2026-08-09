import XCTest

@testable import Orbe

/// worktree の 3 群への振り分け（純粋関数）。**「要らないの推定」と「消して安全か」が別レイヤ**で、
/// 安全確認を 1 つでも落とした worktree が safe に入らないことを固定する。
final class DispatchWorktreeClassifierTests: OrbeTestCase {

  private func classify(_ facts: DispatchCleanFacts...) -> [CleanRow] {
    DispatchWorktreeClassifier.classify(facts)
  }

  private func row(_ facts: DispatchCleanFacts) -> CleanRow {
    DispatchWorktreeClassifier.classify([facts])[0]
  }

  // MARK: - 群の振り分け

  /// Issue #84 の実測ケース: upstream は消えているが独自コミットが残る → **caution**（初期選択に入らない）。
  func testGoneWithOwnCommitsStaysCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/wt-path-template", branch: "ship/wt", isGone: true,
        closedPR: DispatchCleanPR(number: 120, isMerged: false), unmergedCommits: 6))
    XCTAssertEqual(r.group, .caution)
    XCTAssertEqual(r.chips, [.gone, .unmergedClosed(6)], "推定チップの後に落ちた安全確認の理由")
  }

  /// PR が MERGED で安全確認を全部通れば safe。実体のあるディレクトリなので `clean · +0` を出す。
  func testMergedPRPassingEveryCheckIsSafe() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/dispatch-delete", branch: "feat/dispatch-delete",
        closedPR: DispatchCleanPR(number: 142, isMerged: true), unmergedCommits: 0))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.mergedPR(142), .cleanNote])
  }

  /// 未コミット変更があれば推定が立っていても safe に入らない。
  func testDirtyFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/diff-panel", branch: "fix/diff-panel", isGone: true, isDirty: true,
        unmergedCommits: 0))
    XCTAssertEqual(r.group, .caution)
    XCTAssertEqual(r.chips, [.gone, .dirty])
  }

  /// 実体が無い（prunable）なら「ディスク上に失うものが無い」ので dirty の項目は自動的に満たす。
  /// ただし clean を名乗る作業ツリーが無いので `clean · +0` は出さない。
  func testPrunableIsSafeWithoutCleanNote() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/render-batching", branch: "perf/render-batching", isPrunable: true,
        isDirty: true, unmergedCommits: 0))
    XCTAssertEqual(r.group, .safe)
    XCTAssertEqual(r.chips, [.prunable])
  }

  /// locked は `--force` 1 個では外れないので caution に置く（必ず失敗する初期チェックを作らない）。
  func testLockedFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/held", branch: "feat/held", lockReason: "USB", isGone: true,
        unmergedCommits: 0))
    XCTAssertEqual(r.group, .caution)
    XCTAssertEqual(r.chips, [.gone, .locked])
  }

  /// 取り込み済み判定ができなかった行は safe に入らない（分からないものを安全と名乗らない）。
  func testUnknownMergeStateFallsToCaution() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/x", branch: "feat/x", isGone: true, unmergedCommits: nil))
    XCTAssertEqual(r.group, .caution)
    XCTAssertEqual(r.chips, [.gone], "件数を名乗れないので独自コミットのチップは出さない")
  }

  func testMainWorktreeIsInUse() {
    let r = row(DispatchCleanFacts(path: "/repo", branch: "main", isMain: true))
    XCTAssertEqual(r.group, .inUse)
    XCTAssertEqual(r.chips, [.mainWorktree])
  }

  /// ペインが開いていれば推定も安全確認も関係なく inUse。agent の状態が行末に出る。
  func testOccupiedWorktreeIsInUse() {
    let r = row(
      DispatchCleanFacts(
        path: "/wt/agent-hooks", branch: "feature/agent-hooks", isGone: true, unmergedCommits: 0,
        occupancy: PaneOccupancy(cwd: "/wt/agent-hooks", agentState: "working")))
    XCTAssertEqual(r.group, .inUse)
    XCTAssertEqual(r.chips, [.paneOpen(working: true)])
  }

  /// 推定が 1 つも立たなければ、安全確認を通っていても候補にはしない。
  func testNoHintStaysCaution() {
    let r = row(DispatchCleanFacts(path: "/wt/plain", branch: "feat/plain", unmergedCommits: 0))
    XCTAssertEqual(r.group, .caution)
    XCTAssertTrue(r.chips.isEmpty, "言うべき事実が無ければチップも出さない")
  }

  /// PR 情報が無ければ「未マージ close」ではなく素の独自コミット件数を出す。
  func testOwnCommitsWithoutPRInfo() {
    let r = row(
      DispatchCleanFacts(path: "/wt/x", branch: "feat/x", isGone: true, unmergedCommits: 2))
    XCTAssertEqual(r.chips, [.gone, .ownCommits(2)])
  }

  // MARK: - 並びと件数

  func testRowsAreOrderedByGroup() {
    let rows = classify(
      DispatchCleanFacts(path: "/repo", branch: "main", isMain: true),
      DispatchCleanFacts(path: "/wt/dirty", branch: "a", isGone: true, isDirty: true),
      DispatchCleanFacts(path: "/wt/safe", branch: "b", isGone: true, unmergedCommits: 0))
    XCTAssertEqual(rows.map(\.name), ["safe", "dirty", "repo"], "safe → caution → inUse の群順")
    XCTAssertEqual(DispatchWorktreeClassifier.candidateCount(rows), 1, "候補件数は safe 群から導く")
  }

  func testMetaJoinsPathAndBranch() {
    let r = row(DispatchCleanFacts(path: "/wt/x", branch: "feat/x"))
    XCTAssertEqual(r.meta, "/wt/x · feat/x")
    XCTAssertEqual(row(DispatchCleanFacts(path: "/wt/x")).meta, "/wt/x", "detached はパスだけ")
  }

  // MARK: - ペイン占有の帰属

  /// 子ディレクトリにいるペインも占有。判定はパス構成要素単位で、文字列 prefix ではない。
  func testOccupancyMatchesChildDirectoryButNotSiblingPrefix() {
    let map = DispatchWorktreeClassifier.occupancies(
      worktreePaths: ["/a/foo"],
      panes: [PaneOccupancy(cwd: "/a/foo/src/deep", agentState: nil)])
    XCTAssertNotNil(map["/a/foo"], "子ディレクトリは占有")

    let sibling = DispatchWorktreeClassifier.occupancies(
      worktreePaths: ["/a/foo"], panes: [PaneOccupancy(cwd: "/a/foobar", agentState: nil)])
    XCTAssertTrue(sibling.isEmpty, "接頭辞が一致するだけの兄弟は占有ではない")
  }

  /// 入れ子の worktree では最も長く一致した方に帰属する（親と子の両方を占有にしない）。
  func testOccupancyPrefersLongestMatch() {
    let map = DispatchWorktreeClassifier.occupancies(
      worktreePaths: ["/a/repo", "/a/repo/wt/child"],
      panes: [PaneOccupancy(cwd: "/a/repo/wt/child/src", agentState: nil)])
    XCTAssertNil(map["/a/repo"])
    XCTAssertNotNil(map["/a/repo/wt/child"])
  }

  /// symlink（macOS の `/tmp` → `/private/tmp`）を解決してから突き合わせる。
  /// OSC 7 が報告する pwd と `git worktree list` のパスは素では一致しないことがある。
  func testOccupancyResolvesSymlinks() throws {
    let name = "orbe-occupancy-\(UUID().uuidString)"
    let path = "/tmp/\(name)"
    try FileManager.default.createDirectory(
      atPath: path, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let map = DispatchWorktreeClassifier.occupancies(
      worktreePaths: [path],
      panes: [PaneOccupancy(cwd: "/private/tmp/\(name)", agentState: nil)])
    XCTAssertNotNil(map[path])
  }

  /// 同じ worktree に複数ペインが居たら waiting > working > done で 1 つに畳む。
  func testOccupancyFoldsByAgentPriority() {
    let map = DispatchWorktreeClassifier.occupancies(
      worktreePaths: ["/wt/x"],
      panes: [
        PaneOccupancy(cwd: "/wt/x", agentState: "done"),
        PaneOccupancy(cwd: "/wt/x/sub", agentState: "waiting"),
        PaneOccupancy(cwd: "/wt/x", agentState: "working"),
      ])
    XCTAssertEqual(map["/wt/x"]?.agentState, "waiting")
  }
}
