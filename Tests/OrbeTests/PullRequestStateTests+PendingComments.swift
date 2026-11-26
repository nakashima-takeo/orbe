import OrbeTestSupport
import XCTest

@testable import Orbe

/// 未送信のコメントの一覧（`pendingComments`）——最後に読めたレビューのやりとりの未送信のコメントだけを、パスの順 → 行の順
/// （行を持たないものはそのファイルの最後）→ 書いた時刻の順に並べ、今の diff に置けないものを置けないと示す。
///
/// 壊れると何が起きるか: レビューのポップアップの「未送信のコメント」に送信済みのコメントが混ざる・レビューに追加したコメントが出ない・
/// 並びがファイルと行の順にならない。行を持たないスレッドのコメントの行を押すと、diff に無い場所へ移ろうとする。読み直して
/// 送信済みになったコメントが一覧に残る。
extension PullRequestStateTests {
  /// 未送信のコメントだけを、パス → 行（行を持たないものはそのファイルの最後）→ 書いた時刻の順に並べ、行を持たないスレッドの
  /// コメントを置けないと示す。読み直せば、その答えの一覧になる。
  func testPendingCommentsAreListedByPathLineAndTimeFromTheLastRead() {
    let state = PullRequestState.shared(for: key, source: gitHub.source)
    state.beginWatching()
    addTeardownBlock { @MainActor in state.endWatching() }
    let early = Date(timeIntervalSince1970: 100)
    let late = Date(timeIntervalSince1970: 200)
    let threads = [
      thread("T_b", path: "b", line: 1, [comment("b-1", at: early)]),
      thread("T_a_file", path: "a", line: nil, [comment("a-file", at: early)]),
      thread(
        "T_a5_late", path: "a", line: 5,
        [comment("a5-sent", at: early, pending: false), comment("a5-late", at: late)]),
      thread("T_a2", path: "a", line: 2, [comment("a2", at: late)]),
      thread("T_a5_early", path: "a", line: 5, [comment("a5-early", at: early)]),
    ]
    gitHub.content = .success(content())
    gitHub.review = .success(
      GitHubPullRequestReview(
        viewerIsAuthor: false, headCommit: "h", pendingReview: .init(id: "R", commentCount: 5),
        threads: threads))
    state.reload()

    XCTAssertEqual(
      state.pendingComments.map(\.id), ["a2", "a5-early", "a5-late", "a-file", "b-1"],
      "送信済みのコメントを除き、パス → 行 → 時刻の順。行を持たないものはそのファイルの最後")
    XCTAssertEqual(state.pendingComments.filter { !$0.isPlaceable }.map(\.id), ["a-file"])

    gitHub.review = .success(
      GitHubPullRequestReview(
        viewerIsAuthor: false, headCommit: "h", pendingReview: .init(id: "R", commentCount: 1),
        threads: [threads[0]]))
    state.reload()
    XCTAssertEqual(state.pendingComments.map(\.id), ["b-1"], "読み直した答えの一覧になる")
  }

  /// コメントを `comments` の順に持つ、パス `path` の行 `line` の新しい側のスレッド。
  private func thread(
    _ id: String, path: String, line: Int?, _ comments: [GitHubPullRequestReview.Comment]
  ) -> GitHubPullRequestReview.Thread {
    GitHubPullRequestReview.Thread(
      id: id, path: path, side: .new, line: line, isResolved: false, canReply: true,
      canResolve: true, canUnresolve: false, comments: comments)
  }

  /// 時刻 `date` に書いたコメント（`pending` が偽なら送信済み）。
  private func comment(_ id: String, at date: Date, pending: Bool = true)
    -> GitHubPullRequestReview.Comment
  {
    GitHubPullRequestReview.Comment(
      id: id, author: "me", body: "本文", createdAt: date, isPending: pending)
  }
}
