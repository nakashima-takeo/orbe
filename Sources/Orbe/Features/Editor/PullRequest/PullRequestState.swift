import Foundation

/// 状態の変化を受ける者（その PR を見ている worktree の今の PR と、PR の diff）。
@MainActor
protocol PullRequestStateObserver: AnyObject {
  func pullRequestStateDidChange(_ state: PullRequestState)
}

/// PR ごとの状態——最後に読めた中身、確認済み（GitHub が返した値と、書いている途中の値）、レビューのやりとり、コメントの
/// 書きかけ、diff の両端、最後の失敗。手元のリポジトリ（`git-common-dir`）と PR の同一性ごとに 1 つで、アプリが動いている間
/// 持つ。PR のパネルと PR の diff が同じものを見るので、確認済みと書きかけが面やウインドウで食い違わない。
///
/// GitHub に問い合わせるのは見ている者（`beginWatching`）がいる間だけ。中身とレビューのやりとりを読み直すきっかけは、誰も見ていない状態から
/// 見ている者が現れた・`reload`・PR のリポジトリで Orbe の中のネット操作が終わった・PR の先頭のブランチかベースブランチの
/// 追跡 ref の値が前と変わった、のどれか（→ `PullRequestState+Watch`）。読んでいる間に次の読み直しが来たら、終わった後に
/// 1 回だけ読み直す。読み直しに失敗しても、前に読めた中身は残す。
@MainActor @Observable
final class PullRequestState {
  struct Key: Hashable {
    /// 手元のリポジトリの `git-common-dir`。
    let commonDir: String
    let id: GitHubItemID
  }

  /// PR が比べる両端のコミット（GitHub が返した中身の、基準のベース側のコミットと PR の先頭のコミット）。
  struct Ends: Hashable {
    let base: String
    let head: String
  }

  /// diff の両端——マージベース（古い側）、PR の先頭（新しい側）、その間の rename（新しいパス → 元のパス）。
  struct DiffEnds: Hashable {
    let mergeBase: String
    let head: String
    let renames: [String: String]
  }

  /// diff の両端が求まらない理由。
  enum BoundsFailure: Equatable {
    /// PR のコミットが手元に無く、取りに行っても揃わない（浅いクローンで、共通の祖先が浅い境界より古いときを含む）。
    case commitsMissing
    /// ベースブランチと共通のコミットがない。
    case unrelated
    /// git が読めない。
    case unreadable
  }

  /// 中身の両端ごとの、diff の両端。
  enum Bounds: Equatable {
    case none
    /// 求めている（手元に無いコミットを取りに行っている間を含む）。
    case fetching(Ends)
    case ready(Ends, DiffEnds)
    case failed(Ends, BoundsFailure)

    var ends: Ends? {
      switch self {
      case .none: nil
      case .fetching(let ends), .ready(let ends, _), .failed(let ends, _): ends
      }
    }
  }

  let key: Key
  @ObservationIgnored let source: PullRequestSource
  /// git に問い合わせるリポジトリと、PR のコミットを取りに行く remote（PR が置かれたリポジトリを指す remote）と、PR の
  /// 先頭のブランチが置かれたリポジトリを指す remote。worktree の今の PR が結ぶ。
  @ObservationIgnored private(set) var repo: GitRepo?
  @ObservationIgnored private(set) var fetchRemote: String?
  @ObservationIgnored private(set) var headRemote: String?
  /// 見られている間に観測している根のサービス（`repo` の根）。
  @ObservationIgnored var files: RootFiles?
  /// PR の先頭のブランチとベースブランチの追跡 ref。
  @ObservationIgnored lazy var tracking = TrackingRefs { [weak self] done in
    guard let self, let repo else { return done(nil) }
    done((repo, trackedRefs))
  }
  /// 最後に読めた中身と、その変更ファイルの並び・パスからの索引（中身を読んだときに作り直す）。
  private(set) var content: GitHubPullRequestContent?
  private(set) var changedFiles = PrChangedFiles.empty {
    didSet { changedFilesVersion &+= 1 }
  }
  /// `changedFiles` が変わるたびに進む（未送信のコメントの一覧を組み直す合図）。
  private(set) var changedFilesVersion = 0
  /// 中身の最後の読みの失敗。次に中身が読めたら消える（読み直している間は前の失敗を残す）。
  var contentFailure: GitHubFailure?
  /// 最後の確認済みの書き込みの失敗。失敗の知らせを閉じたとき・次の確認済みの書き込みを始めたときに消える。
  var viewedFailure: GitHubFailure?
  private(set) var isReading = false
  private(set) var bounds = Bounds.none

  /// 確認済みの GitHub の値（パス → 値）と、その値を決めた問い合わせの通し番号。
  var viewed: [String: Bool] = [:] {
    didSet { viewedVersion &+= 1 }
  }
  @ObservationIgnored var viewedOrder: [String: Int] = [:]
  /// 書いている途中・書く順番を待っている値（パス → 値と、その書き込みの通し番号）。
  var pendingViewed: [String: PendingViewed] = [:] {
    didSet { viewedVersion &+= 1 }
  }
  /// 見せる確認済み（`isViewed`）が変わりうるたびに進む（列が見えている行を描き直す合図）。
  private(set) var viewedVersion = 0
  @ObservationIgnored var writes: [ViewedWrite] = []
  @ObservationIgnored var isWriting = false

  /// 最後に読めたレビューのやりとり（→ `PullRequestState+Review`）。
  var review: GitHubPullRequestReview? {
    didSet { reviewVersion &+= 1 }
  }
  /// `review` が変わるたびに進む（列が見えている行を描き直す合図）。
  private(set) var reviewVersion = 0
  /// 最後に組んだ未送信のコメントの一覧（→ `PullRequestState+PendingComments`）。
  @ObservationIgnored var pendingCommentsMade: PendingCommentsMade?
  /// レビューのやりとりの最後の読みの失敗。中身の読みの失敗とは分けて持ち、次に読めたら消える。
  var reviewFailure: GitHubFailure?
  /// レビューの送信の、全体へのコメントの書きかけと選んだ種類（メモリだけで、パネルを隠しても残る）。
  var reviewDraft = ReviewDraft()
  /// 最後のレビューの送信の失敗。失敗の知らせを閉じたとき・次に送るときに消える。
  var submissionFailure: GitHubFailure?
  /// スレッドへの返信の書きかけと、新しいコメントの書きかけ（→ `PullRequestState+CommentDrafts`）。
  @ObservationIgnored var commentDrafts = CommentDrafts()
  @ObservationIgnored var commentDraftsObservers: [WeakCommentDraftsObserver] = []
  /// レビューへの書き込みが走っている対象と、順番を待っている対象。
  var reviewWriteTargets: Set<ReviewTarget> = []
  @ObservationIgnored var reviewWrites: [ReviewWrite] = []
  @ObservationIgnored var isSendingReviewWrite = false
  @ObservationIgnored var isReadingReview = false
  @ObservationIgnored var readReviewAgain = false
  /// 最後にレビューへの書き込みの答えが届いた時点の通し番号。これより前に出した読みの答えは入れない。
  @ObservationIgnored var reviewWrittenOrder = 0
  /// 次に届く新しい読みを待っている書き込みの続き。
  @ObservationIgnored var reviewReadWaiters: [() -> Void] = []
  /// 書き込みが名指しする自分の未送信のレビュー（読みの答えと、書き込みの答えで分かったもの）。
  @ObservationIgnored var pendingReviewID: String?
  /// 今の中身と、今のレビューのやりとりを読んだ問い合わせの通し番号（読みが通った時点で進む）。
  @ObservationIgnored private var contentOrder = 0
  @ObservationIgnored var reviewOrder = 0
  /// 最後に答えが届いた（通った・失敗した）中身とレビューのやりとりの読みの通し番号。
  @ObservationIgnored private var contentAnsweredOrder = 0
  @ObservationIgnored var reviewAnsweredOrder = 0
  /// 先頭のコミットを揃える読み直し（→ `alignHeads`）。走っていれば、その読みを出す直前の通し番号と、揃え始めてから
  /// 読んだ先頭のコミット。
  @ObservationIgnored private var alignment: (start: Int, seen: Set<String>)?
  /// 読み直しと書き込みに付ける、出した順の通し番号。
  @ObservationIgnored private var nextOrder = 0

  @ObservationIgnored private var watchers = 0
  @ObservationIgnored private var readAgain = false
  @ObservationIgnored private var observers: [WeakObserver] = []

  struct PendingViewed: Equatable {
    let value: Bool
    let order: Int
  }

  struct ViewedWrite {
    let value: Bool
    let paths: Set<String>
    let nodeID: String
    let order: Int
  }

  private struct WeakObserver {
    weak var value: PullRequestStateObserver?
  }

  private static var registry: [Key: PullRequestState] = [:]

  /// `key` の状態。無ければ `source` で作る。
  static func shared(for key: Key, source: PullRequestSource) -> PullRequestState {
    if let live = registry[key] { return live }
    let state = PullRequestState(key: key, source: source)
    registry[key] = state
    return state
  }

  private init(key: Key, source: PullRequestSource) {
    self.key = key
    self.source = source
  }

  // MARK: - 結び付け・観測

  /// git に問い合わせるリポジトリと、コミットを取りに行く remote と、PR の先頭のブランチの remote を結ぶ。見られていれば
  /// そのリポジトリを観測し、両端を求められるなら求める。
  func attach(repo: GitRepo, fetchRemote: String?, headRemote: String?) {
    self.repo = repo
    self.fetchRemote = fetchRemote
    self.headRemote = headRemote
    observe()
    resolveBounds()
  }

  func addObserver(_ observer: PullRequestStateObserver) {
    observers.removeAll { $0.value == nil || $0.value === observer }
    observers.append(WeakObserver(value: observer))
  }

  func removeObserver(_ observer: PullRequestStateObserver) {
    observers.removeAll { $0.value == nil || $0.value === observer }
  }

  func notify() {
    for observer in observers { observer.value?.pullRequestStateDidChange(self) }
  }

  /// 見ている者が現れた。誰も見ていなかったなら、PR のリポジトリを観測し、中身を読み直し、両端を求め直す——見ている者が
  /// いない間に求めるのをやめた両端（見ている者が、取りに行く前に・中身を読む間に去った）も揃える。見ている者が増えた
  /// だけなら、読み直さない。
  func beginWatching() {
    watchers += 1
    guard watchers == 1 else { return }
    observe()
    reload()
    resolveBounds()
  }

  /// 見ている者が去った。最後の 1 人なら観測をやめる。
  func endWatching() {
    guard watchers > 0 else { return }
    watchers -= 1
    if watchers == 0 { unobserve() }
  }

  var isWatched: Bool { watchers > 0 }

  // MARK: - 中身

  /// 中身とレビューのやりとりを読み直す（見ている者がいるときだけ）。両端が求まらなかったなら、求め直す。
  func reload() {
    guard isWatched else { return }
    if case .failed = bounds { bounds = .none }
    guard !isReading else {
      readAgain = true
      return
    }
    // 新しいきっかけでは、先頭のコミットを揃える読み直しを最初から数える。
    alignment = nil
    startReading()
  }

  /// 中身とレビューのやりとりを読む。中身を読む道はこの 1 つ。問い合わせる前の追跡 ref の値を覚えてから問い合わせる
  /// （→ worktree の今の PR と同じ）。読めたら前の失敗を外し、読めなければその失敗を持つ。
  private func startReading() {
    isReading = true
    let order = issueOrder()
    notify()
    tracking.record { [weak self] _ in
      // 中身の読みが印の付いたまま（`isReading`）で、レビューのやりとりの読みを先に出す——答えがすぐ返っても、中身の答えより
      // 先に先頭のコミットを見比べない。
      self?.readReview()
      self?.readContent(order: order)
    }
  }

  private func readContent(order: Int) {
    // 追跡 ref を読む間に見ている者がいなくなったら、GitHub に問い合わせない（次に見ている者が現れたときに読み直す）。
    guard isWatched else { return stopReading() }
    source.content(key.id) { [weak self] result in
      guard let self else { return }
      isReading = false
      contentAnsweredOrder = order
      switch result {
      case .success(let read):
        apply(read, order: order)
        contentOrder = order
        contentFailure = nil
        // 中身が読めて追跡 ref が新しく分かったら、その値も覚える。
        if trackedRefs.contains(where: tracking.lacks) { tracking.record() }
      case .failure(let reason): contentFailure = reason
      }
      if readAgain {
        readAgain = false
        reload()
      }
      resolveBounds()
      alignHeads()
      notify()
    }
  }

  /// 中身とレビューのやりとりを読んだ時点の PR の先頭のコミットが食い違っていたら、両方を読み直して揃える（書き込みの後の
  /// 読み直しはレビューのやりとりだけなので、その間に push があると、レビューのやりとりだけが新しい先頭を読む。中身とレビューの
  /// やりとりを並べて読む間に push があっても食い違う。そのままではスレッドを置けず、新しいスレッドも受け付けない）。
  ///
  /// どちらの答えが古いかは、出した順からも届いた順からも決まらないので、当てにいかない。両方の答えが届いて食い違っていたら、
  /// それより後に出す読みで両方を読み直す。GitHub の答えが一貫していれば、その 2 本の間に push が無い限り揃う。なお食い
  /// 違っていて、揃え始めてから見ていない先頭のコミットが現れたら（間に push があった）、もう一度読み直す。現れなければ（GitHub の
  /// 答えが一貫していない）、次のきっかけまで読まない。揃える読みが失敗したら、その失敗を見せて揃えるのをやめ、次のきっかけで
  /// また揃えにいく。どちらかを読んでいる間は待ち、両方が届いた後に見直す。誰も見ていない間は読まない。
  func alignHeads() {
    guard !isReading, !isReadingReview else { return }
    guard let content, let review, content.headCommit != review.headCommit else {
      alignment = nil
      return
    }
    let heads: Set = [content.headCommit, review.headCommit]
    var seen = heads
    if let alignment {
      // 揃える読みの答えが両方届くまで待つ。
      guard contentAnsweredOrder > alignment.start, reviewAnsweredOrder > alignment.start else {
        return
      }
      self.alignment = nil
      // 揃える読みのどちらかが失敗した。
      guard contentOrder > alignment.start, reviewOrder > alignment.start else { return }
      guard !heads.isSubset(of: alignment.seen) else { return }
      seen.formUnion(alignment.seen)
    }
    guard isWatched else { return }
    alignment = (issueOrder(), seen)
    startReading()
  }

  /// 中身とレビューのやりとりの先頭のコミットが食い違ったまま、揃える読みをやめている（次のきっかけ——再読込など——まで
  /// 読まない）。
  var stoppedAligning: Bool {
    guard let content, let review, content.headCommit != review.headCommit else { return false }
    return alignment == nil && !isReading && !isReadingReview
  }

  /// 問い合わせずに読むのをやめる（積んだ読み直しも捨てる）。
  private func stopReading() {
    isReading = false
    readAgain = false
    notify()
  }

  /// 出した順の通し番号を 1 つ出す。
  func issueOrder() -> Int {
    nextOrder += 1
    return nextOrder
  }

  /// 読めた中身を入れる。確認済みは、その読み直しより後に出した書き込みで決まったパスでは上書きしない。
  private func apply(_ read: GitHubPullRequestContent, order: Int) {
    if read.files != content?.files { changedFiles = PrChangedFiles(read.files) }
    content = read
    for file in read.files where (viewedOrder[file.path] ?? 0) < order {
      viewed[file.path] = file.isViewed
      viewedOrder[file.path] = order
    }
  }

  // MARK: - diff の両端

  /// 中身の両端に対する diff の両端を求める（見ている者がいて、中身とリポジトリがあり、その両端でまだ求めていないとき）。
  /// マージベースを求め、どちらかのコミットが手元に無いと返ったときだけ、両端のコミットを取りに行ってもう一度求める。
  private func resolveBounds() {
    guard isWatched, let content, let repo else { return }
    let ends = Ends(base: content.baseCommit, head: content.headCommit)
    guard bounds.ends != ends else { return }
    bounds = .fetching(ends)
    mergeBase(ends, in: repo, fetched: false)
  }

  private func mergeBase(_ ends: Ends, in repo: GitRepo, fetched: Bool) {
    repo.mergeBase(ends.base, ends.head) { [weak self] found in
      guard let self, bounds == .fetching(ends) else { return }
      switch found {
      case .found(let mergeBase):
        repo.renames(from: mergeBase, to: ends.head) { [weak self] renames in
          guard let self, bounds == .fetching(ends) else { return }
          bounds =
            renames.map {
              .ready(ends, DiffEnds(mergeBase: mergeBase, head: ends.head, renames: $0))
            }
            ?? .failed(ends, .unreadable)
          notify()
        }
      case .missingCommit:
        // 求める間に見ている者がいなくなったら、取りに行かない（次に見ている者が現れたときに求め直す）。
        guard isWatched else {
          bounds = .none
          return
        }
        guard !fetched, let remote = fetchRemote else {
          bounds = .failed(ends, .commitsMissing)
          return notify()
        }
        repo.fetch(
          commits: [ends.base, ends.head], from: remote, handle: GitRunner.Handle()
        ) { [weak self] _ in self?.mergeBase(ends, in: repo, fetched: true) }
      case .unrelated:
        bounds = .failed(ends, .unrelated)
        notify()
      case .shallow:
        // 両端は手元に在り、浅い境界でたどれない——取ってきても求まらないので、fetch しない。
        bounds = .failed(ends, .commitsMissing)
        notify()
      case .failed:
        bounds = .failed(ends, .unreadable)
        notify()
      }
    }
  }
}
