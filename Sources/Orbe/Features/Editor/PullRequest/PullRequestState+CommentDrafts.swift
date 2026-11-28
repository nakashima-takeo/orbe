import Foundation

/// コメントの書きかけの変化を受ける者（PR の diff のコメントの層）。中身の変化（`PullRequestStateObserver`）とは別に知らせる
/// ——打鍵のたびに、PR のパネルの一覧の行を作り直させない。
@MainActor
protocol PullRequestCommentDraftsObserver: AnyObject {
  func pullRequestCommentDraftsDidChange(_ state: PullRequestState)
}

/// コメントの書きかけ——PR の diff のスレッドへの返信と新しいコメントの、まだ送っていない本文と欄の位置。PR ごとに 1 つで、
/// どのコメントの層も同じものを読み書きするので、diff を閉じても・連が替わっても残り、同じ PR の diff を 2 か所で開いていれば
/// 両方に同じ書きかけが出る。アプリを終えると消える。空白と改行だけの本文は書きかけとして持たない（欄が空なのと同じ）ので、
/// 持っている書きかけは、そのファイルの diff を開けば欄に出る（置ける行が無いときを除く）。欄の位置は書きかけを作ったときの値で、
/// 作った後は書き換えない——push の後にどの行へ移るか・行が無くなったかは、各層が、この位置から自分が見せている両端へ
/// その都度導く（古い両端を見せている層が、新しい両端で数えた位置を壊さない）。知らせるのは書きかけの追加と削除と本文の変化だけ。
extension PullRequestState {
  /// 書きかけの欄の位置——行の範囲（0 始まり）と、その行を数えた diff の両端と両側の本文（ほかの両端での行を導くのに使う）。
  struct CommentSpot: Equatable {
    let range: DiffLineRange
    let ends: DiffEnds
    let basis: EditorDiff.SideTexts
  }

  /// スレッドへの返信の書きかけ。スレッドの値は最後に読めたもの（GitHub から消えたスレッドも、開き直した diff に描く）。位置は、
  /// 書きかけを作ったときにスレッドが置かれていた位置。
  struct ReplyDraft {
    var body: String
    var thread: GitHubPullRequestReview.Thread
    let spot: CommentSpot
  }

  /// 新しいコメントの書きかけ。位置は欄を開いた位置。
  struct CommentDraft {
    let path: String
    var body: String
    let spot: CommentSpot
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

  /// 本文 `body` に、空白と改行のほかの字がある（書きかけとして持つ）。
  nonisolated static func hasText(_ body: String) -> Bool { !body.allSatisfy(\.isWhitespace) }

  private func notifyCommentDrafts() {
    for observer in commentDraftsObservers {
      observer.value?.pullRequestCommentDraftsDidChange(self)
    }
  }

  // MARK: - 返信

  /// スレッド `thread` への返信の本文を `body` にする。書きかけが無ければ、位置 `spot` で作る。在れば本文だけを書き換える
  /// （位置とスレッドの値には触れない）。空白と改行だけなら書きかけを消す。
  func writeReply(_ body: String, to thread: GitHubPullRequestReview.Thread, from spot: CommentSpot)
  {
    guard Self.hasText(body) else { return removeReply(to: thread.id) }
    if let draft = commentDrafts.replies[thread.id] {
      guard draft.body != body else { return }
      commentDrafts.replies[thread.id]?.body = body
    } else {
      commentDrafts.replies[thread.id] = ReplyDraft(body: body, thread: thread, spot: spot)
    }
    notifyCommentDrafts()
  }

  /// 読めたレビューのやりとり `review` のスレッドの値で、返信の書きかけのスレッドの値を差し替える（読めなかったスレッドは
  /// 最後の値のまま）。
  func refreshReplyThreads(from review: GitHubPullRequestReview) {
    for thread in review.threads where commentDrafts.replies[thread.id] != nil {
      commentDrafts.replies[thread.id]?.thread = thread
    }
  }

  func removeReply(to thread: String) {
    guard commentDrafts.replies.removeValue(forKey: thread) != nil else { return }
    notifyCommentDrafts()
  }

  // MARK: - 新しいコメント

  /// 新しいコメントの欄の通し番号を 1 つ出す（欄を開いたとき。空白と改行のほかの字が入るまで書きかけは持たない）。
  func issueCommentSerial() -> Int {
    commentDrafts.lastSerial += 1
    return commentDrafts.lastSerial
  }

  /// 通し番号 `serial` の新しいコメントの本文を `body` にする。書きかけが無ければ、ファイル `path` の位置 `spot` で作る。在れば
  /// 本文だけを書き換える。空白と改行だけなら書きかけを消す。
  func writeComment(_ serial: Int, path: String, body: String, from spot: CommentSpot) {
    guard Self.hasText(body) else { return removeComment(serial) }
    if let draft = commentDrafts.comments[serial] {
      guard draft.body != body else { return }
      commentDrafts.comments[serial]?.body = body
    } else {
      commentDrafts.comments[serial] = CommentDraft(path: path, body: body, spot: spot)
    }
    notifyCommentDrafts()
  }

  func removeComment(_ serial: Int) {
    guard commentDrafts.comments.removeValue(forKey: serial) != nil else { return }
    notifyCommentDrafts()
  }
}
