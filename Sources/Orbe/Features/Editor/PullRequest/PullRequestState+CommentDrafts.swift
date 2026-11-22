import Foundation

/// コメントの書きかけの変化を受ける者（PR の diff のコメントの層）。中身の変化（`PullRequestStateObserver`）とは別に知らせる
/// ——打鍵のたびに、PR のパネルの一覧の行を作り直させない。
@MainActor
protocol PullRequestCommentDraftsObserver: AnyObject {
  func pullRequestCommentDraftsDidChange(_ state: PullRequestState)
}

/// コメントの書きかけ——PR の diff のスレッドへの返信と新しいコメントの、まだ送っていない本文と欄の位置。PR ごとに 1 つで、
/// どのコメントの層も同じものを読み書きするので、diff を閉じても・連が替わっても残り、同じ PR の diff を 2 か所で開いていれば
/// 両方に同じ書きかけが出る。アプリを終えると消える。本文が空（字が 1 つも無い）の書きかけは持たない。知らせるのは書きかけの
/// 追加と削除と本文の変化だけで、欄の位置とスレッドの値の書き戻しは知らせない（開き直した diff が読む）。
extension PullRequestState {
  /// 書きかけの欄の位置——側と行（0 始まり）と、その行を数えた diff の両端と両側の本文（push の後に行を移すのに使う）。
  struct CommentSpot: Equatable {
    let side: GitHubDiffSide
    let line: Int
    let ends: DiffEnds
    let basis: EditorDiff.SideTexts
  }

  /// スレッドへの返信の書きかけ。スレッドの値は最後に読めたもの（GitHub から消えたスレッドも、開き直した diff に描く）。
  struct ReplyDraft {
    var body: String
    var thread: GitHubPullRequestReview.Thread
    var spot: CommentSpot
  }

  /// 新しいコメントの書きかけ。
  struct CommentDraft {
    let path: String
    var body: String
    var spot: CommentSpot
    /// 欄の行が今の版に無い（→ `PrCommentPlacement.isGone`）。
    var isGone: Bool
  }

  struct CommentDrafts {
    /// スレッドの id → 返信の書きかけ。
    var replies: [String: ReplyDraft] = [:]
    /// 通し番号 → 新しいコメントの書きかけ。
    var comments: [Int: CommentDraft] = [:]
    var lastSerial = 0
  }

  struct WeakCommentDraftsObserver {
    weak var value: PullRequestCommentDraftsObserver?
  }

  func addCommentDraftsObserver(_ observer: PullRequestCommentDraftsObserver) {
    commentDraftsObservers.removeAll { $0.value == nil || $0.value === observer }
    commentDraftsObservers.append(WeakCommentDraftsObserver(value: observer))
  }

  func removeCommentDraftsObserver(_ observer: PullRequestCommentDraftsObserver) {
    commentDraftsObservers.removeAll { $0.value == nil || $0.value === observer }
  }

  private func notifyCommentDrafts() {
    for observer in commentDraftsObservers {
      observer.value?.pullRequestCommentDraftsDidChange(self)
    }
  }

  // MARK: - 返信

  /// スレッド `thread` への返信の本文を `body` にする（空なら書きかけを消す）。欄の位置は `spot`。
  func setReply(_ body: String, to thread: GitHubPullRequestReview.Thread, at spot: CommentSpot) {
    let changed = commentDrafts.replies[thread.id]?.body != (body.isEmpty ? nil : body)
    commentDrafts.replies[thread.id] =
      body.isEmpty ? nil : ReplyDraft(body: body, thread: thread, spot: spot)
    if changed { notifyCommentDrafts() }
  }

  /// スレッド `thread` への返信の書きかけがあれば、スレッドの値と欄の位置を置き換える。
  func placeReply(to thread: GitHubPullRequestReview.Thread, at spot: CommentSpot) {
    guard commentDrafts.replies[thread.id] != nil else { return }
    commentDrafts.replies[thread.id]?.thread = thread
    commentDrafts.replies[thread.id]?.spot = spot
  }

  func removeReply(to thread: String) {
    guard commentDrafts.replies.removeValue(forKey: thread) != nil else { return }
    notifyCommentDrafts()
  }

  // MARK: - 新しいコメント

  /// 新しいコメントの欄の通し番号を 1 つ出す（欄を開いたとき。本文が入るまで書きかけは持たない）。
  func issueCommentSerial() -> Int {
    commentDrafts.lastSerial += 1
    return commentDrafts.lastSerial
  }

  /// 通し番号 `serial` の新しいコメントの本文を `body` にする（空なら書きかけを消す）。
  func setComment(
    _ serial: Int, path: String, body: String, at spot: CommentSpot, isGone: Bool
  ) {
    let changed = commentDrafts.comments[serial]?.body != (body.isEmpty ? nil : body)
    commentDrafts.comments[serial] =
      body.isEmpty
      ? nil : CommentDraft(path: path, body: body, spot: spot, isGone: isGone)
    if changed { notifyCommentDrafts() }
  }

  /// 通し番号 `serial` の新しいコメントの書きかけがあれば、欄の位置と、行が無くなったかを置き換える。
  func moveComment(_ serial: Int, to spot: CommentSpot, isGone: Bool) {
    guard commentDrafts.comments[serial] != nil else { return }
    commentDrafts.comments[serial]?.spot = spot
    commentDrafts.comments[serial]?.isGone = isGone
  }

  func removeComment(_ serial: Int) {
    guard commentDrafts.comments.removeValue(forKey: serial) != nil else { return }
    notifyCommentDrafts()
  }
}
