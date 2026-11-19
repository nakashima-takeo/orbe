#if DEBUG
  import Foundation

  /// PR のパネルと PR の diff の gallery / flow の、差し替えの GitHub のレビューのやりとり。見本（orbe_design の `editor/data.ts`
  /// の `thread`）のスレッド（StateHooks.swift の新しい側の行 12。you の保留中のコメントと、もう 1 人の返信）に、古い側の行の
  /// Markdown 入りのスレッド・解決済みのスレッド・今の diff に置けないスレッド・README.md のスレッドを足した姿を答える。
  /// 書き込みは GitHub と同じく次の読みに出る（返信・解決・新しいスレッドは保留中のレビューに積み、送信で公開する）。
  /// `writes` で、書き込みの答えを返さない（書き込みの最中を撮る）・失敗を返す、に替えられる。
  final class PrFixtureReview {
    enum Writes {
      case succeed
      /// 答えを返さない（`release` で返す）。
      case hold
      /// 失敗を返す。
      case fail(GitHubFailure)
    }

    var writes = Writes.succeed
    private let head: String
    private var threads: [GitHubPullRequestReview.Thread]
    private var pendingID: String? = "PRR_1"
    private var held: [() -> Void] = []
    private var serial = 0

    static let path = "src/agent/StateHooks.swift"

    init(head: String) {
      self.head = head
      let now = Date()
      let ago = { (minutes: Double) in now.addingTimeInterval(-minutes * 60) }
      threads = [
        Self.thread(
          "T_coalesce", line: 12,
          [
            .init(
              id: "C_1", author: "you",
              body: "tail だけ見ると、間に別種のイベントが挟まったときに畳み損ねない？ `merges(event)` の前に種別チェックが要る気がする。",
              createdAt: ago(5), isPending: true),
            .init(
              id: "C_2", author: "claude",
              body:
                "意図的に tail のみです。tail 以外を畳むとキュー順序が崩れます。挟まった場合は畳まず append する分岐を `merges` 側に足し、テストを追加しました。",
              createdAt: ago(3), isPending: false),
          ]),
        Self.thread(
          "T_legacy", side: .old, line: 10,
          [
            .init(
              id: "C_3", author: "octocat",
              body: """
                **旧い経路**では `append` の後に `notify` を *毎回* 呼んでいた。

                - 呼ぶ回数: ~~イベントごと~~ → まとめて 1 回
                - 経緯は [設計メモ](https://example.com/hooks) に

                ```swift
                buffer.append(event)
                renderer.notify(.hooksDidEmit)
                ```

                > 描画は最新の状態だけを見せればよい
                """,
              createdAt: ago(180), isPending: false)
          ]),
        Self.thread(
          "T_count", line: 22, resolved: true,
          [
            .init(
              id: "C_4", author: "claude", body: "数は描画の負荷の目安として残します。", createdAt: ago(60 * 26),
              isPending: false)
          ]),
        Self.thread(
          "T_outdated", line: nil,
          [
            .init(
              id: "C_5", author: "octocat", body: "前の版の行のコメント", createdAt: ago(60 * 50),
              isPending: false)
          ]),
        Self.thread(
          "T_readme", path: "README.md", line: 3,
          [
            .init(
              id: "C_6", author: "octocat", body: "「畳んでから」の意味を補ってください。", createdAt: ago(90),
              isPending: false)
          ]),
      ]
    }

    private static func thread(
      _ id: String, path: String = path, side: GitHubDiffSide = .new, line: Int?,
      resolved: Bool = false, _ comments: [GitHubPullRequestReview.Comment]
    ) -> GitHubPullRequestReview.Thread {
      GitHubPullRequestReview.Thread(
        id: id, path: path, side: side, line: line, isResolved: resolved, canReply: true,
        canResolve: !resolved, canUnresolve: resolved, comments: comments)
    }

    func read() -> GitHubPullRequestReview {
      GitHubPullRequestReview(
        viewer: "you", viewerIsAuthor: false, headCommit: head,
        pendingReview: pendingID.map {
          .init(id: $0, commentCount: threads.flatMap(\.comments).count(where: \.isPending))
        }, threads: threads)
    }

    func write(_ write: GitHubReviewWrite, completion: @escaping (GitHubReviewWriteResult) -> Void)
    {
      switch writes {
      case .succeed:
        apply(write)
        completion(GitHubReviewWriteResult(pendingReview: pendingID, failure: nil))
      case .hold:
        held.append { [weak self] in
          self?.apply(write)
          completion(GitHubReviewWriteResult(pendingReview: self?.pendingID, failure: nil))
        }
      case .fail(let failure):
        completion(GitHubReviewWriteResult(pendingReview: pendingID, failure: failure))
      }
    }

    /// 返さずにおいた書き込みの答えを返す。
    func release() {
      let answers = held
      held = []
      for answer in answers { answer() }
    }

    private func apply(_ write: GitHubReviewWrite) {
      serial += 1
      switch write {
      case .addThread(let path, let side, let line, _, let body):
        if pendingID == nil { pendingID = "PRR_\(serial)" }
        threads.append(
          Self.thread("T_written_\(serial)", path: path, side: side, line: line, [comment(body)]))
      case .reply(let id, let body, let resolve):
        if pendingID == nil { pendingID = "PRR_\(serial)" }
        update(id) { thread in
          var comments = thread.comments
          comments.append(comment(body))
          return Self.thread(
            thread.id, path: thread.path, side: thread.side, line: thread.line,
            resolved: thread.isResolved || resolve, comments)
        }
      case .setResolved(let id, let resolved):
        update(id) { thread in
          Self.thread(
            thread.id, path: thread.path, side: thread.side, line: thread.line, resolved: resolved,
            thread.comments)
        }
      case .submit:
        pendingID = nil
        threads = threads.map { thread in
          Self.thread(
            thread.id, path: thread.path, side: thread.side, line: thread.line,
            resolved: thread.isResolved,
            thread.comments.map {
              .init(
                id: $0.id, author: $0.author, body: $0.body, createdAt: $0.createdAt,
                isPending: false)
            })
        }
      }
    }

    private func comment(_ body: String) -> GitHubPullRequestReview.Comment {
      .init(
        id: "C_written_\(serial)", author: "you", body: body, createdAt: Date(), isPending: true)
    }

    private func update(
      _ id: String, _ body: (GitHubPullRequestReview.Thread) -> GitHubPullRequestReview.Thread
    ) {
      threads = threads.map { $0.id == id ? body($0) : $0 }
    }
  }
#endif
