import XCTest

@testable import Orbe

/// タスクの行が、そのタスクの結び付きと置き場の答え・自分の login から、主の印と番号・PR の札・
/// 「レビュー」を持つこと。出し方の規則そのものは `GitHubItemTextTests` が持つ。
///
/// 壊れると何が起きるか: 行が置き場の答えや自分の login を受け取らないと、値が届いても行は番号だけの
/// ままで、PR の札の状態も「レビュー」も出ない。
extension TaskPaletteRowsTests {
  func testRowCarriesTheLinkMarksFromTheTasksLinksAndTheGitHubValues() throws {
    let primaryIssue = TaskPaletteSamples.link(.issue, 212)
    let pr = TaskPaletteSamples.link(.pr, 213)
    let othersPR = TaskPaletteSamples.link(.pr, 88)
    let items: [GitHubItemID: GitHubItemAnswer] = [
      pr.item: .found(
        GitHubItemSummary(
          title: "pr", state: .open,
          pullRequest: .init(isDraft: false, review: .approved, checks: .success, author: "me"))),
      othersPR.item: .found(
        GitHubItemSummary(
          title: "pr", state: .open,
          pullRequest: .init(isDraft: false, review: nil, checks: nil, author: "sato"))),
    ]

    let issueRow = try taskRow(
      task(1) { $0.links = [primaryIssue, pr] }, items: items, viewerLogin: "me")
    let reviewRow = try taskRow(task(2) { $0.links = [othersPR] }, items: items, viewerLogin: "me")

    XCTAssertEqual(issueRow.link, .init(kind: .issue, number: 212))
    XCTAssertEqual(issueRow.pullRequest, .init(number: 213, phase: .approved, checks: .success))
    XCTAssertFalse(issueRow.needsReview)
    XCTAssertEqual(reviewRow.link, .init(kind: .pr, number: 88))
    XCTAssertTrue(reviewRow.needsReview)
  }
}
