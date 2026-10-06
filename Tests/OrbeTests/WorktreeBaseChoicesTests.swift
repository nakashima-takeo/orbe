import XCTest

@testable import Orbe

/// ベースの選択肢の列（純関数）。壊れると、同じブランチがボタン 2 つに割れる・「ほか…」が列の途中に来て
/// 巡回が別の画面に入る、のどちらかになる。
final class WorktreeBaseChoicesTests: OrbeTestCase {

  private func roles(_ choices: [WorktreeBaseChoice]) -> [WorktreeBaseRole] { choices.map(\.role) }

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
}
