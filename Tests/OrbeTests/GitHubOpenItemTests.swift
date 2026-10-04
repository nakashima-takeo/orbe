import XCTest

@testable import Orbe

/// open 一覧の 1 項目（`GitHubOpenItem`）を GraphQL の `issues` / `pullRequests` のノードから読む規則。
///
/// 壊れると何が起きるか: PR が Issue の区分に出る。チーム宛のレビュー依頼が個人宛と読まれ、「レビュー依頼 ·
/// あなた宛」と誤って出る、または「自分をレビュアーにする」の判定が狂う。消えたアカウントの作成者が 1 件
/// 混じっただけで、そのページの項目がまるごと出なくなる。
final class GitHubOpenItemTests: OrbeTestCase {
  private func decode(_ json: String) throws -> GitHubOpenItem {
    try JSONDecoder().decode(GitHubOpenItem.self, from: Data(json.utf8))
  }

  func testPullRequestNodeSplitsPersonalAndTeamReviewRequests() throws {
    let item = try decode(
      #"""
      {"__typename":"PullRequest","number":214,"title":"t","updatedAt":"2026-10-04T12:00:00Z",
       "author":{"login":"alice"},"assignees":{"nodes":[{"login":"bob"}]},
       "isDraft":true,"reviewDecision":"CHANGES_REQUESTED",
       "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]},
       "reviewRequests":{"nodes":[
         {"requestedReviewer":{"__typename":"User","login":"me"}},
         {"requestedReviewer":{"__typename":"Team","slug":"core","organization":{"login":"orbe"}}},
         {"requestedReviewer":{"__typename":"Bot"}},
         {"requestedReviewer":null}]}}
      """#)

    XCTAssertEqual(item.kind, .pr)
    XCTAssertEqual(item.updatedAt, ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z"))
    XCTAssertEqual(item.author, "alice")
    XCTAssertEqual(item.assignees, ["bob"])
    XCTAssertEqual(
      item.pullRequest,
      .init(
        isDraft: true, review: .changesRequested, checks: .failure, reviewers: ["me"],
        teams: ["orbe/core"]))
  }

  /// Issue は PR の値を持たない。作成者が消えたアカウント（null）でも読める。
  func testIssueNodeHasNoPullRequestValuesAndToleratesAGhostAuthor() throws {
    let item = try decode(
      #"""
      {"__typename":"Issue","number":221,"title":"t","updatedAt":"2026-10-04T12:00:00Z",
       "author":null,"assignees":{"nodes":[]}}
      """#)

    XCTAssertEqual(item.kind, .issue)
    XCTAssertNil(item.pullRequest)
    XCTAssertNil(item.author)
    XCTAssertEqual(item.assignees, [])
  }

  /// 並べ直しの鍵（更新日時）が読めない項目は壊れた応答として扱う。
  func testUnreadableUpdatedAtIsRejected() {
    XCTAssertThrowsError(
      try decode(#"{"__typename":"Issue","number":1,"title":"t","updatedAt":"yesterday"}"#))
  }
}
