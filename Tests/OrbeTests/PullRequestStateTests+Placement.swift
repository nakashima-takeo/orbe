import OrbeTestSupport
import XCTest

@testable import Orbe

/// スレッドの置き方から導いた値（`PullRequestState.Placements`）——diff の両端の様子ごとの、未送信のコメントの置けるか・今の
/// diff に置けない未解決のスレッドの数・ファイルごとのコメント数。
///
/// 壊れると何が起きるか: diff を表示できない PR で、未送信のコメントの行を押すと diff の無い場所へ移ろうとする・ファイルの行に
/// 置けないスレッドのコメント数が出る・置けない未解決のスレッドに気づけない。両端を求めている最中に、古い側の行のスレッドは
/// 置けるか分からないのに置けないと数えてしまい、置けない数とコメント数が揺れる。揃える読みをやめた間、未送信のコメントの行が
/// 押せる姿のまま、押しても何も起きない。
extension PullRequestStateTests {
  /// 新しい側の行（N）・古い側の行（O）・行を持たない（F）の、未送信のコメントを持つ未解決のスレッドを、両端の様子ごとに導く。
  /// F はいつも置けない。求め終えた両端では O も置け、求めている最中と、diff が前の両端を見せている間は O の置けるかが分からず
  /// （一覧では置けるとみなし、数には入れない）、diff を表示できないときはどれも置けない。スレッドを読んだ版が違う間は N と O の
  /// 置けるかが分からず（一覧では置けるとみなし、数には入れない。前に決まった答えも無い）、揃える読みをやめていればどれも
  /// 置けない（置けない数に 3 つとも入る）。
  func testPlacementsFollowTheStateOfTheDiffEnds() {
    let threads = [
      thread("N", side: .new, line: 5, comments: 2),
      thread("O", side: .old, line: 5, comments: 1),
      thread("F", side: .new, line: nil, comments: 1),
    ]
    let ends = PullRequestState.DiffEnds(mergeBase: "b", head: "h", renames: [:])
    let cases = [
      Case(
        "求め終えた", .ready(ends, isCurrent: true), placeable: ["N", "O"], outdated: 1, counts: ["a": 3]
      ),
      Case("求めている最中", .unknown, placeable: ["N", "O"], outdated: 1, counts: ["a": 2]),
      Case("表示できない", .failed, placeable: [], outdated: 3, counts: [:]),
      Case(
        "前の両端を見せている", .ready(ends, isCurrent: false), placeable: ["N", "O"], outdated: 1,
        counts: ["a": 2]),
      Case(
        "読んだ版が違う", .ready(ends, isCurrent: true), readAt: "h0", placeable: ["N", "O"],
        outdated: 1, counts: [:]),
      Case(
        "揃える読みをやめた", .ready(ends, isCurrent: true), readAt: "h0", readsStopped: true,
        placeable: [], outdated: 3, counts: [:]),
    ]
    for item in cases {
      let review = GitHubPullRequestReview(
        viewerIsAuthor: false, headCommit: item.readAt,
        pendingReview: .init(id: "R", commentCount: 3), threads: threads)
      let placements = PullRequestState.Placements(
        PullRequestState.PlacementInputs(
          review: review, head: "h", ends: item.ends, files: .empty, readsStopped: item.readsStopped
        ), previous: .empty)
      XCTAssertEqual(
        placements.pendingComments.filter(\.isPlaceable).map(\.thread).sorted(), item.placeable,
        "\(item.name): 未送信のコメントの置けるか")
      XCTAssertEqual(placements.outdatedThreadCount, item.outdated, "\(item.name): 置けない数")
      XCTAssertEqual(placements.commentCounts, item.counts, "\(item.name): ファイルのコメント数")
    }
  }

  /// 両端の様子 1 つと、そのときに導く値。
  private struct Case {
    let name: String
    let ends: PullRequestState.PlacementEnds
    let readAt: String
    let readsStopped: Bool
    let placeable: [String]
    let outdated: Int
    let counts: [String: Int]

    init(
      _ name: String, _ ends: PullRequestState.PlacementEnds, readAt: String = "h",
      readsStopped: Bool = false, placeable: [String], outdated: Int, counts: [String: Int]
    ) {
      self.name = name
      self.ends = ends
      self.readAt = readAt
      self.readsStopped = readsStopped
      self.placeable = placeable
      self.outdated = outdated
      self.counts = counts
    }
  }

  /// パス a の側 `side` の行 `line` の、`comments` 件のコメント（最後の 1 件が未送信）を持つ未解決のスレッド。
  private func thread(_ id: String, side: GitHubDiffSide, line: Int?, comments: Int)
    -> GitHubPullRequestReview.Thread
  {
    GitHubPullRequestReview.Thread(
      id: id, path: "a", lines: line.map { .at(side, $0) }, isResolved: false, canReply: true,
      canResolve: true, canUnresolve: false,
      comments: (1...comments).map {
        .init(
          id: "\(id)-\($0)", author: "me", body: "本文", createdAt: Date(timeIntervalSince1970: 0),
          isPending: $0 == comments)
      })
  }
}
