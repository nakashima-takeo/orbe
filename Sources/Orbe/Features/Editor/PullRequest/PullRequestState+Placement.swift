import Foundation

/// スレッドの置き方——スレッドを diff に置けるかの決まり（1 つ）と、それから導く未送信のコメントの一覧・今の diff に置けない
/// 未解決のスレッドの数・ファイルごとのコメント数。コメントの層・ポップアップ・PR の一覧のどれもが、この決まりを読む。
extension PullRequestState {
  /// スレッドを diff に置けるか。
  ///
  /// 「まだ分からない」は、読む側ごとに次のように扱う（ここだけに書く）:
  /// - コメントの層: 置かない（決まるまで待つ。返信の書きかけがあれば行を追う欄に残す）。
  /// - ポップアップの未送信のコメントの一覧: 置けるとみなす（押せば diff を開き、置かれたら見せる）。
  /// - 今の diff に置けない未解決のスレッドの数: 数えない。
  /// - PR の一覧のファイルの行のコメント数: 数えない。
  enum Placement: Equatable {
    case placeable
    case unplaceable
    case unknown
  }

  /// 置き方を決める diff の両端の様子。
  enum PlacementEnds: Equatable {
    /// 求めている最中（まだ求めていない・中身の先頭が変わって求め直す前を含む）。
    case unknown
    /// 求められない（diff を表示できない）。
    case failed
    /// 求め終えた両端。`isCurrent` は、それが今の PR の両端か（diff が新しい両端の本文を読み終えるまでは、前の両端を見せる）。
    case ready(DiffEnds, isCurrent: Bool)
  }

  /// 置き方の決まり。スレッド `thread`（レビューのやりとりを先頭 `readAt` で読んだもの）を、先頭 `head` の版の、両端の様子
  /// `ends` の diff に置けるか。`renamed` は、GitHub が rename と答えた変更ファイルのパス。
  /// - 行を持たない（ファイル単位）・diff を表示できない → 置けない。
  /// - スレッドを読んだ版と diff の版が違う・分からない → まだ分からない（揃う読みを待つ）。
  /// - 新しい側の行 → 置ける。
  /// - 古い側の行 → 今の PR の両端を求め終えていれば、rename の判定が GitHub と手元で同じなら置け、違えば置けない（古い側の
  ///   行の対応が変わる）。求めている最中・diff が前の両端を見せている間は、まだ分からない。
  nonisolated static func placement(
    of thread: GitHubPullRequestReview.Thread, readAt: String?, head: String?,
    ends: PlacementEnds, renamed: Set<String>
  ) -> Placement {
    guard thread.line != nil, ends != .failed else { return .unplaceable }
    guard let head, readAt == head else { return .unknown }
    guard thread.side == .old else { return .placeable }
    guard case .ready(let ends, isCurrent: true) = ends else { return .unknown }
    return renamed.contains(thread.path) == (ends.renames[thread.path] != nil)
      ? .placeable : .unplaceable
  }

  /// diff が両端 `ends` を見せているときの、スレッド `thread` の置き方（コメントの層が読む）。
  func placement(of thread: GitHubPullRequestReview.Thread, shown ends: DiffEnds) -> Placement {
    Self.placement(
      of: thread, readAt: review?.headCommit, head: ends.head,
      ends: .ready(ends, isCurrent: diffEnds == ends), renamed: renamedPaths)
  }

  /// GitHub が rename と答えた変更ファイルのパス。
  private var renamedPaths: Set<String> {
    Set((content?.files ?? []).filter { $0.change == .renamed }.map(\.path))
  }

  // MARK: - 導いた値

  /// 未送信のコメント 1 件。
  struct PendingComment: Equatable {
    /// コメントの id。
    let id: String
    let thread: String
    let path: String
    let side: GitHubDiffSide
    /// スレッドが付いた行（その側の版の行。1 始まり）。行を持たないスレッドなら nil。
    let line: Int?
    let body: String
    /// 今の diff に置ける（置き方が「まだ分からない」間は、置けるとみなす）。
    let isPlaceable: Bool
  }

  /// 置き方の材料——最後に読めたレビューのやりとり・中身の先頭・diff の両端の様子・GitHub が rename と答えたパス。
  struct PlacementInputs {
    let review: GitHubPullRequestReview?
    let head: String?
    let ends: PlacementEnds
    let renamed: Set<String>
  }

  /// 置き方から導いた値。材料（`PlacementInputs`）だけから作る。
  struct Placements {
    /// 最後に読めたレビューのやりとりの、未送信のコメント。並びはパスの順 → 行の順（行を持たないものはそのファイルの最後）→
    /// 書いた時刻の順。
    let pendingComments: [PendingComment]
    /// 今の先頭で読んだスレッドのうち、今の diff に置けない未解決のスレッドの数。
    let outdatedThreadCount: Int
    /// ファイルごとの、今の先頭で読んだ、今の diff に置けるスレッドのコメントの総数。
    let commentCounts: [String: Int]

    static let empty = Placements(pendingComments: [], outdatedThreadCount: 0, commentCounts: [:])

    init(_ inputs: PlacementInputs) {
      let threads = inputs.review?.threads ?? []
      let placement = { (thread: GitHubPullRequestReview.Thread) in
        PullRequestState.placement(
          of: thread, readAt: inputs.review?.headCommit, head: inputs.head, ends: inputs.ends,
          renamed: inputs.renamed)
      }
      let found = threads.flatMap { thread in
        thread.comments.filter(\.isPending).map { (thread: thread, comment: $0) }
      }
      pendingComments = found.sorted { a, b in
        if a.thread.path != b.thread.path { return a.thread.path < b.thread.path }
        if a.thread.line != b.thread.line {
          return (a.thread.line ?? .max) < (b.thread.line ?? .max)
        }
        return (a.comment.createdAt, a.comment.id) < (b.comment.createdAt, b.comment.id)
      }.map { thread, comment in
        PendingComment(
          id: comment.id, thread: thread.id, path: thread.path, side: thread.side,
          line: thread.line,
          body: comment.body, isPlaceable: placement(thread) != .unplaceable)
      }
      let current = inputs.review?.headCommit == inputs.head ? threads : []
      outdatedThreadCount = current.count { !$0.isResolved && placement($0) == .unplaceable }
      var counts: [String: Int] = [:]
      for thread in current where placement(thread) == .placeable {
        counts[thread.path, default: 0] += thread.comments.count
      }
      commentCounts = counts
    }

    private init(
      pendingComments: [PendingComment], outdatedThreadCount: Int, commentCounts: [String: Int]
    ) {
      self.pendingComments = pendingComments
      self.outdatedThreadCount = outdatedThreadCount
      self.commentCounts = commentCounts
    }
  }

  /// 置き方の材料。作り直すのは、ここで読む値（レビューのやりとり・中身・diff の両端）が変わった直後だけで、それぞれの
  /// `didSet` が `refreshPlacements` を呼ぶ。ここで読む値を足したら、その値の `didSet` にも足す——足し忘れは、デバッグの
  /// ビルドで導いた値を読むときに止まる（→ `placements`）。
  private var placementInputs: PlacementInputs {
    let ends: PlacementEnds
    switch bounds {
    case .ready(let at, let diffEnds) where at.head == content?.headCommit:
      ends = .ready(diffEnds, isCurrent: true)
    case .failed(let at, _)
    where at == content.map { Ends(base: $0.baseCommit, head: $0.headCommit) }:
      ends = .failed
    default:
      ends = .unknown
    }
    return PlacementInputs(
      review: review, head: content?.headCommit, ends: ends, renamed: renamedPaths)
  }

  /// 置き方から導いた値を、今の材料で作り直す。デバッグのビルドでは、材料を読んだ値の変化を見張り、作り直す前に変わったら
  /// 印を付ける。
  func refreshPlacements() {
    #if DEBUG
      let inputs = withObservationTracking {
        placementInputs
      } onChange: { [weak self] in
        MainActor.assumeIsolated { self?.placementsAreStale = true }
      }
      placementsAreStale = false
    #else
      let inputs = placementInputs
    #endif
    placementsMade = Placements(inputs)
  }

  /// 置き方から導いた値。
  var placements: Placements {
    assert(!placementsAreStale, "置き方の材料が変わったのに作り直していない（材料の didSet を確かめる）")
    return placementsMade
  }

  var pendingComments: [PendingComment] { placements.pendingComments }
  var outdatedThreadCount: Int { placements.outdatedThreadCount }
}
