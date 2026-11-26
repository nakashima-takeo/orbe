import Foundation

/// レビューのやりとり——スレッドと未送信のレビューを読み、書き込み（スレッドの追加・返信・解決・レビューの送信）を PR ごとに
/// 1 つずつ順に送る。書き込みは、レスポンスが届いた後にレビューのやりとりを読み直し、その読み直しのレスポンスが届いて初めて
/// 終わる（結果は、書き込みを頼んだ呼び出し元へ 1 回だけ返す）。書き込みのレスポンスより前に出した読みのレスポンスは、GitHub が
/// 書き込みを受ける前の状態を返しうるので取り込まない。受け付けた書き込みは、見ている者がいなくなっても最後まで順に送る
/// （その後の読み直しはしない）。
extension PullRequestState {
  /// 書き込みの対象。対象への書き込みが走っている間と順番を待っている間は、同じ対象への次の書き込みを受け付けない。
  enum ReviewTarget: Hashable {
    case thread(String)
    /// 新しいコメントの書きかけ（通し番号）。
    case comment(Int)
    /// レビューの送信。
    case submission
  }

  struct ReviewWrite {
    let write: GitHubReviewWrite
    let target: ReviewTarget?
    let nodeID: String
    /// 受け付けた時点のレビューのやりとりを読んだ PR の先頭のコミット（利用者が見ていたもの）。
    let reviewedCommit: String
    let completion: (GitHubReviewWriteResult) -> Void
  }

  /// PR の先頭のコミットが `head` だった時点に読んだスレッド。読んだ時点の先頭のコミットが `head` と違えば nil（古い版の行の
  /// スレッドを、新しい版の行に置かない）。
  func threads(at head: String) -> [GitHubPullRequestReview.Thread]? {
    guard let review, review.headCommit == head else { return nil }
    return review.threads
  }

  /// ファイル `path` が rename かの判定が、GitHub（中身のファイルの列）と手元の diff の両端 `ends` で同じか。違えば、古い側の
  /// 行の対応が GitHub と手元で変わる。
  func agreesOnRename(of path: String, _ ends: DiffEnds) -> Bool {
    (changedFiles.change(of: path) == .renamed) == (ends.renames[path] != nil)
  }

  /// スレッド `thread` を、両端 `ends` の diff の行に置けるか——今の diff の行に付いていて、古い側の行なら rename の判定が
  /// GitHub と手元で同じ。古い側の行のスレッドで両端が分からなければ、決められない（nil）。
  func canPlace(_ thread: GitHubPullRequestReview.Thread, in ends: DiffEnds?) -> Bool? {
    guard thread.line != nil else { return false }
    guard thread.side == .old else { return true }
    return ends.map { agreesOnRename(of: thread.path, $0) }
  }

  /// 今の PR の diff の両端——求め終えていて、その先頭が中身の先頭と同じとき（求めている・求められない・中身が新しい先頭を
  /// 読んだ後で求め直す前は nil）。PR ごとの値で、開いている diff の有無と数に依らない。
  var diffEnds: DiffEnds? {
    guard case .ready(_, let ends) = bounds, ends.head == content?.headCommit else { return nil }
    return ends
  }

  func isWritingReview(_ target: ReviewTarget) -> Bool { reviewWriteTargets.contains(target) }

  /// diff の両端を求め終え、その先頭のコミットで中身とレビューのやりとりも読んでいる（diff・ファイルの列・スレッドと、送る
  /// レビューの版が揃う）。
  var isReviewAligned: Bool {
    guard let content, let review, let ends = diffEnds else { return false }
    return content.headCommit == review.headCommit && ends.head == review.headCommit
  }

  /// レビューへの書き込みを順番に積む。中身とレビューのやりとりがまだ読めていないとき、対象への書き込みが走っているとき、
  /// 新しいスレッドの行を数えた先頭のコミットが、レビューのやりとりを読んだ時点の先頭のコミットと違うとき（`threads(at:)` が
  /// nil の間）、レビューの送信で diff の両端・中身・レビューのやりとりの版が揃っていないとき（`isReviewAligned` が偽の間）
  /// は受け付けず、false を返す。受け付けたら、終わったときに `completion` を 1 回だけ呼ぶ（引数は書き込みの結果。通れば
  /// 失敗の種類が nil。「解決して返信」で返信だけが通ったことも分かる）。
  @discardableResult
  func writeReview(
    _ write: GitHubReviewWrite, completion: @escaping (GitHubReviewWriteResult) -> Void
  ) -> Bool {
    enqueueReview(write, target: Self.target(of: write), completion: completion)
  }

  /// スレッド `thread` への返信の書きかけを送る（`resolve` なら、返信の後にスレッドを解決する）。本文は書きかけから読む。
  /// 受け付けの条件は `writeReview` と同じで、書きかけが無ければ受け付けない。返信が通ったら（「解決して返信」で解決だけが
  /// 通らなかったときも）、書きかけを消してから `completion` を呼ぶ——頼んだ層が消えていても消す（送り直して同じ返信を
  /// 2 つ積まない）。
  @discardableResult
  func sendReply(
    to thread: String, resolve: Bool, completion: @escaping (GitHubReviewWriteResult) -> Void
  ) -> Bool {
    guard let draft = commentDrafts.replies[thread] else { return false }
    let write = GitHubReviewWrite.reply(thread: thread, body: draft.body, resolve: resolve)
    return enqueueReview(write, target: .thread(thread)) { [weak self] result in
      if result.failure == nil || result.replied { self?.removeReply(to: thread) }
      completion(result)
    }
  }

  /// 通し番号 `serial` の新しいコメントの書きかけを、頼んだ層が導いた側 `side`・行 `line`（0 始まり）・両端 `ends` で示す位置に
  /// 新しいスレッドとして送る。`ends` が PR の今の diff の両端（`diffEnds`）と同じときだけ受け付け、新しいスレッドを `ends` の先頭のコミットに結んで書く。ほかの
  /// 受け付けの条件は `writeReview` と同じで、書きかけが無ければ受け付けない。通ったら書きかけを消してから `completion` を呼ぶ。
  @discardableResult
  func sendComment(
    _ serial: Int, side: GitHubDiffSide, line: Int, ends: DiffEnds,
    completion: @escaping (GitHubReviewWriteResult) -> Void
  ) -> Bool {
    guard let draft = commentDrafts.comments[serial], ends == diffEnds else { return false }
    let write = GitHubReviewWrite.addThread(
      path: draft.path, side: side, line: line + 1, commit: ends.head, body: draft.body)
    return enqueueReview(write, target: .comment(serial)) { [weak self] result in
      if result.failure == nil { self?.removeComment(serial) }
      completion(result)
    }
  }

  private func enqueueReview(
    _ write: GitHubReviewWrite, target: ReviewTarget?,
    completion: @escaping (GitHubReviewWriteResult) -> Void
  ) -> Bool {
    guard let content, let review else { return false }
    if case .addThread(_, _, _, let commit, _) = write, commit != review.headCommit { return false }
    if case .submit = write, !isReviewAligned { return false }
    if let target {
      guard !reviewWriteTargets.contains(target) else { return false }
      reviewWriteTargets.insert(target)
    }
    reviewWrites.append(
      ReviewWrite(
        write: write, target: target, nodeID: content.nodeID, reviewedCommit: review.headCommit,
        completion: completion))
    sendNextReviewWrite()
    notify()
    return true
  }

  /// レビューのやりとりを読む（見ている者がいるときだけ）。読んでいる間に次の読み直しが来たら、終わった後に 1 回だけ読み直す。
  /// 見ている者がいなければ GitHub に問い合わせず、読み直しを待っている書き込みをその場で終える。読みの失敗は `reviewFailure`
  /// に持ち、次に読めたら消える。
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
        reviewAnsweredOrder = order
        switch result {
        case .success(let read):
          review = read
          refreshReplyThreads(from: read)
          reviewOrder = order
          reviewFailure = nil
          pendingReviewID = read.pendingReview?.id
        case .failure(let reason): reviewFailure = reason
        }
        finishReviewReadWaiters()
      }
      if readReviewAgain {
        readReviewAgain = false
        readReview()
      }
      alignHeads()
      notify()
    }
  }

  /// 書き込みの対象。新しいスレッドは nil（書きかけから送る `sendComment` は、その書きかけを対象として自分で渡す）。
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
    let answered: (GitHubReviewWriteResult) -> Void = { [weak self] result in
      guard let self else { return }
      pendingReviewID = result.pendingReview
      reviewWrittenOrder = issueOrder()
      // タイムアウトで失敗した書き込みも、GitHub に届いていたかもしれないので読み直す（利用者が同じ書き込みを二重に送らないため）。
      reviewReadWaiters.append { [weak self] in self?.finishReviewWrite(result) }
      readReview()
    }
    source.writeReview(next.write, next.nodeID, pendingReviewID, next.reviewedCommit, answered)
  }

  private func finishReviewWrite(_ result: GitHubReviewWriteResult) {
    let done = reviewWrites.removeFirst()
    isSendingReviewWrite = false
    if let target = done.target { reviewWriteTargets.remove(target) }
    notify()
    done.completion(result)
    sendNextReviewWrite()
  }

  private func finishReviewReadWaiters() {
    let waiters = reviewReadWaiters
    reviewReadWaiters = []
    for waiter in waiters { waiter() }
  }
}
