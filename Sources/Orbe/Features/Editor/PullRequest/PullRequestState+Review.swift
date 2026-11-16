import Foundation

/// レビューのやりとり——スレッドと保留中のレビューを読み、書き込み（スレッドの追加・返信・解決・レビューの送信）を PR ごとに
/// 1 つずつ順に送る。書き込みは、レスポンスが届いた後にレビューのやりとりを読み直し、その読み直しのレスポンスが届いて初めて
/// 終わる（結果は、書き込みを頼んだ呼び出し元へ 1 回だけ返す）。書き込みのレスポンスより前に出した読みのレスポンスは、GitHub が
/// 書き込みを受ける前の状態を返しうるので取り込まない。走っている書き込みは、見ている者がいなくなっても最後まで走る（その後の
/// 読み直しはしない）。
extension PullRequestState {
  /// 書き込みの対象。対象への書き込みが走っている間と順番を待っている間は、同じ対象への次の書き込みを受け付けない。
  enum ReviewTarget: Hashable {
    case thread(String)
    /// レビューの送信。
    case submission
  }

  struct ReviewWrite {
    let write: GitHubReviewWrite
    let target: ReviewTarget?
    let nodeID: String
    let completion: (GitHubFailure?) -> Void
  }

  /// PR の先頭のコミットが `head` だった時点に読んだスレッド。読んだ時点の先頭のコミットが `head` と違えば nil（古い版の行の
  /// スレッドを、新しい版の行に置かない）。
  func threads(at head: String) -> [GitHubPullRequestReview.Thread]? {
    guard let review, review.headCommit == head else { return nil }
    return review.threads
  }

  func isWriting(_ target: ReviewTarget) -> Bool { reviewWriteTargets.contains(target) }

  /// レビューへの書き込みを順番に積む。中身とレビューのやりとりがまだ読めていないとき、対象への書き込みが走っているとき、
  /// 新しいスレッドの行を数えた先頭のコミットが、レビューのやりとりを読んだ時点の先頭のコミットと違うとき（`threads(at:)` が
  /// nil の間）は受け付けず、false を返す。受け付けたら、終わったときに `completion` を 1 回だけ呼ぶ（引数は失敗の種類。通れば
  /// nil）。
  @discardableResult
  func write(_ write: GitHubReviewWrite, completion: @escaping (GitHubFailure?) -> Void) -> Bool {
    guard let content, let review else { return false }
    if case .addThread(_, _, _, let commit, _) = write, commit != review.headCommit { return false }
    let target = Self.target(of: write)
    if let target {
      guard !reviewWriteTargets.contains(target) else { return false }
      reviewWriteTargets.insert(target)
    }
    reviewWrites.append(
      ReviewWrite(write: write, target: target, nodeID: content.nodeID, completion: completion))
    sendNextReviewWrite()
    notify()
    return true
  }

  /// レビューのやりとりを読む（見ている者がいるときだけ）。読んでいる間に次の読み直しが来たら、終わった後に 1 回だけ読み直す。
  /// 見ている者がいなければ GitHub に問い合わせず、読み直しを待っている書き込みをその場で終える。
  func readReview() {
    guard isWatched else {
      readReviewAgain = false
      return finishReviewReadWaiters()
    }
    guard !isReadingReview else {
      readReviewAgain = true
      return
    }
    isReadingReview = true
    let order = issueOrder()
    source.review(key.id) { [weak self] result in
      guard let self else { return }
      isReadingReview = false
      if order > reviewWrittenOrder {
        switch result {
        case .success(let read):
          review = read
          pendingReviewID = read.pendingReview?.id
        case .failure(let reason): failure = .read(reason)
        }
        finishReviewReadWaiters()
      }
      if readReviewAgain {
        readReviewAgain = false
        readReview()
      }
      notify()
    }
  }

  private static func target(of write: GitHubReviewWrite) -> ReviewTarget? {
    switch write {
    case .addThread: nil
    case .reply(let thread, _, _), .setResolved(let thread, _): .thread(thread)
    case .submit: .submission
    }
  }

  private func sendNextReviewWrite() {
    guard !isSendingReviewWrite, let next = reviewWrites.first else { return }
    isSendingReviewWrite = true
    source.writeReview(next.write, next.nodeID, pendingReviewID) { [weak self] result in
      guard let self else { return }
      pendingReviewID = result.pendingReview
      reviewWrittenOrder = issueOrder()
      // タイムアウトで失敗した書き込みも、GitHub に届いていたかもしれないので読み直す（利用者が同じ書き込みを二重に送らないため）。
      reviewReadWaiters.append { [weak self] in self?.finishReviewWrite(failure: result.failure) }
      readReview()
    }
  }

  private func finishReviewWrite(failure: GitHubFailure?) {
    let done = reviewWrites.removeFirst()
    isSendingReviewWrite = false
    if let target = done.target { reviewWriteTargets.remove(target) }
    notify()
    done.completion(failure)
    sendNextReviewWrite()
  }

  private func finishReviewReadWaiters() {
    let waiters = reviewReadWaiters
    reviewReadWaiters = []
    for waiter in waiters { waiter() }
  }
}
