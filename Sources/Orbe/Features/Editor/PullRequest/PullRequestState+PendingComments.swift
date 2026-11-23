import Foundation

/// 保留中のコメントの一覧と、今の diff に置けないスレッド。どちらも最後に読めたレビューのやりとりと diff の両端から導く。
extension PullRequestState {
  /// 保留中のコメント 1 件。
  struct PendingComment: Equatable {
    /// コメントの id。
    let id: String
    let thread: String
    let path: String
    let side: GitHubDiffSide
    /// スレッドが付いた行（その側の版の行。1 始まり）。行を持たないスレッドなら nil。
    let line: Int?
    let body: String
    /// 今の diff に置ける（diff の両端が分からない間は、置けるとみなす）。
    let isPlaceable: Bool
  }

  /// 組んだ保留中のコメントの一覧と、組んだときのレビューのやりとりの版・diff の両端。
  struct PendingCommentsMade {
    let version: Int
    let ends: DiffEnds?
    let comments: [PendingComment]
  }

  /// 最後に読めたレビューのやりとりの、保留中のコメント。並びはパスの順 → 行の順（行を持たないものはそのファイルの最後）→
  /// 書いた時刻の順。組み直すのは、レビューのやりとりか diff の両端が変わったときだけ（参照するたびにスレッドをたどらない）。
  var pendingComments: [PendingComment] {
    let ends = diffEnds
    if let made = pendingCommentsMade, made.version == reviewVersion, made.ends == ends {
      return made.comments
    }
    let found = (review?.threads ?? []).flatMap { thread in
      thread.comments.filter(\.isPending).map { (thread: thread, comment: $0) }
    }
    let comments = found.sorted { a, b in
      if a.thread.path != b.thread.path { return a.thread.path < b.thread.path }
      if a.thread.line != b.thread.line { return (a.thread.line ?? .max) < (b.thread.line ?? .max) }
      return (a.comment.createdAt, a.comment.id) < (b.comment.createdAt, b.comment.id)
    }.map { thread, comment in
      PendingComment(
        id: comment.id, thread: thread.id, path: thread.path, side: thread.side, line: thread.line,
        body: comment.body, isPlaceable: canPlace(thread, in: ends) != false)
    }
    pendingCommentsMade = PendingCommentsMade(
      version: reviewVersion, ends: ends, comments: comments)
    return comments
  }

  /// 今の diff に置けない未解決のスレッド（古い版の行に付いたもの、ファイル単位のもの、rename の判定が GitHub と手元で食い違う
  /// ファイルの古い側の行に付いたもの）の数。
  var outdatedThreadCount: Int {
    guard let head = content?.headCommit else { return 0 }
    let ends = diffEnds
    return (threads(at: head) ?? []).count { !$0.isResolved && canPlace($0, in: ends) == false }
  }
}
