import XCTest

@testable import Orbe

/// ベースの選択肢の列（純関数）と、作成行の衝突の規則。壊れると、同じブランチがボタン 2 つに割れる・
/// 「ほか…」が列の途中に来て巡回が別の画面に入る・作成が必ず失敗する名前に作成行が出る、のどれかになる。
final class WorktreeBaseChoicesTests: OrbeTestCase {

  private func roles(_ choices: [WorktreeBaseChoice]) -> [WorktreeBaseRole] { choices.map(\.role) }

  func testOrderIsPreviousDefaultCurrentPickedThenOther() {
    let choices = WorktreeBaseChoices.build(
      facts: WorktreeBaseFacts(previous: "origin/rel", defaultBranch: "origin/main", current: "a"),
      picked: "b")
    XCTAssertEqual(roles(choices), [.previous, .defaultBranch, .current, .picked, .other])
    XCTAssertEqual(
      choices.map(\.base), [.ref("origin/rel"), .defaultBranch, .ref("a"), .ref("b"), nil])
  }

  /// 同じ名前に解決するものは 1 つにまとめ、前に来る役割の札を残す。
  func testSameNameMergesIntoTheEarlierRole() {
    let choices = WorktreeBaseChoices.build(
      facts: WorktreeBaseFacts(
        previous: "origin/main", defaultBranch: "origin/main", current: "origin/main"),
      picked: "origin/main")
    XCTAssertEqual(roles(choices), [.previous, .other])
  }

  /// detached（現在が無い）・前回が無い・まだ選んでいないときは、その選択肢を出さない。「ほか…」は常にある。
  func testMissingFactsAreLeftOut() {
    let choices = WorktreeBaseChoices.build(
      facts: WorktreeBaseFacts(previous: nil, defaultBranch: "main", current: nil), picked: nil)
    XCTAssertEqual(roles(choices), [.defaultBranch, .other])
    XCTAssertEqual(roles(WorktreeBaseChoices.build(facts: nil, picked: nil)), [.other])
  }

  func testInitialRoleIsPreviousElseDefault() {
    let withPrevious = WorktreeBaseChoices.build(
      facts: WorktreeBaseFacts(previous: "p", defaultBranch: "d", current: "c"), picked: nil)
    XCTAssertEqual(WorktreeBaseChoices.initialRole(in: withPrevious), .previous)
    let withoutPrevious = WorktreeBaseChoices.build(
      facts: WorktreeBaseFacts(previous: nil, defaultBranch: "d", current: "c"), picked: nil)
    XCTAssertEqual(WorktreeBaseChoices.initialRole(in: withoutPrevious), .defaultBranch)
  }

  // MARK: - 作成行の衝突の規則

  private let rules = WorktreeNewBranchRules(
    takenNames: ["main", "feat/x"], worktreePaths: ["/src/repo-worktrees/issue-1"],
    template: WorktreePathTemplate.defaultTemplate, repoPath: "/src/repo")

  func testTakenNamesAreNotCreatable() {
    XCTAssertFalse(rules.allows("main"))
    XCTAssertFalse(rules.allows("feat/x"))
    XCTAssertTrue(rules.allows("feat/y"))
  }

  /// 作成先（テンプレートで解いたパス）が既存の worktree と同じになる名前は出さない。`/` と `-` は同じ slug。
  func testNamesLandingOnAnExistingWorktreeAreNotCreatable() {
    XCTAssertFalse(rules.allows("issue-1"))
    XCTAssertFalse(rules.allows("issue/1"))
    XCTAssertTrue(rules.allows("issue/2"))
  }
}
