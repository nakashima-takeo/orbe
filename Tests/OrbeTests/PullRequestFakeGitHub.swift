@testable import Orbe

@MainActor
/// 差し替えの構造体の相手——中身とレビューのやりとりの答えと、確認済みとレビューへの書き込みの完了を、テストが好きな順に
/// 返す。
final class PullRequestFakeGitHub {
  var content: Result<GitHubPullRequestContent, GitHubFailure> = .failure(.reason(""))
  private(set) var contentRequests: [(Result<GitHubPullRequestContent, GitHubFailure>) -> Void] =
    []
  private(set) var writes: [PullRequestFakeWrite] = []
  /// 中身の問い合わせに、すぐ答えるか（偽なら `answerContent` まで待つ）。
  var answersAtOnce = true
  /// 中身の問い合わせの回数。
  private(set) var contentReads = 0
  /// レビューのやりとりの答え。nil なら、スレッドが無く、今の中身と同じ先頭を読んだ姿で答える（2 つの読みの先頭が食い違うと、
  /// 状態は先頭を揃えるために読み直す）。
  var review: Result<GitHubPullRequestReview, GitHubFailure>?
  private(set) var reviewRequests: [(Result<GitHubPullRequestReview, GitHubFailure>) -> Void] =
    []
  /// レビューのやりとりの問い合わせに、すぐ答えるか（偽なら `answerReview` まで待つ）。
  var answersReviewAtOnce = true
  /// レビューのやりとりの問い合わせの回数。
  private(set) var reviewReads = 0
  private(set) var reviewWrites: [PullRequestFakeReviewWrite] = []

  var source: PullRequestSource {
    PullRequestSource(
      branchPullRequests: { _, _, _ in },
      branchExists: { _, _ in },
      content: { [unowned self] _, completion in
        contentReads += 1
        if answersAtOnce { completion(content) } else { contentRequests.append(completion) }
      },
      setViewed: { [unowned self] viewed, paths, _, completion in
        writes.append(PullRequestFakeWrite(viewed: viewed, paths: paths, done: completion))
      },
      review: { [unowned self] _, completion in
        reviewReads += 1
        if answersReviewAtOnce {
          completion(reviewAnswer)
        } else {
          reviewRequests.append(completion)
        }
      },
      writeReview: { [unowned self] write, _, pendingReview, reviewedCommit, completion in
        reviewWrites.append(
          PullRequestFakeReviewWrite(
            write: write, pendingReview: pendingReview, reviewedCommit: reviewedCommit,
            done: completion))
      })
  }

  func answerReview() {
    reviewRequests.removeFirst()(reviewAnswer)
  }

  private var reviewAnswer: Result<GitHubPullRequestReview, GitHubFailure> {
    review
      ?? .success(
        GitHubPullRequestReview(
          viewerIsAuthor: false, headCommit: (try? content.get())?.headCommit ?? "h",
          pendingReview: nil, threads: []))
  }

  /// 最初のレビューへの書き込みを、その後の未送信のレビューが `pendingReview`（省けば送る前のまま）として返す。
  func finishReviewWrite(pendingReview: String?? = .none, failure: GitHubFailure? = nil) {
    let write = reviewWrites.removeFirst()
    write.done(
      GitHubReviewWriteResult(
        pendingReview: pendingReview ?? write.pendingReview, failure: failure))
  }

  func answerContent(at index: Int = 0) {
    contentRequests.remove(at: index)(content)
  }

  /// 書き込み `index` を、`written` のパスが通った（`failure` なら残りは通らなかった）として返す。
  func finishWrite(_ index: Int = 0, written: Set<String>? = nil, failure: GitHubFailure? = nil) {
    let write = writes.remove(at: index)
    write.done(GitHubViewedWrite(written: written ?? write.paths, failure: failure))
  }
}

/// 差し替えの構造体が受けたレビューへの書き込み 1 回。
struct PullRequestFakeReviewWrite {
  let write: GitHubReviewWrite
  /// 送る前に分かっていた未送信のレビュー。
  let pendingReview: String?
  /// 利用者が見ていたレビューのやりとりを読んだ時点の PR の先頭のコミット。
  let reviewedCommit: String
  let done: (GitHubReviewWriteResult) -> Void
}

/// 差し替えの構造体が受けた確認済みの書き込み 1 回。
struct PullRequestFakeWrite {
  let viewed: Bool
  let paths: Set<String>
  let done: (GitHubViewedWrite) -> Void
}
