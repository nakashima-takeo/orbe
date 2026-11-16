import Foundation

/// 状態の変化を受ける者（その PR を見ている worktree の今の PR と、PR の diff）。
@MainActor
protocol PullRequestStateObserver: AnyObject {
  func pullRequestStateDidChange(_ state: PullRequestState)
}

/// PR ごとの状態——最後に読めた中身、確認済み（GitHub が返した値と、書いている途中の値）、diff の両端、最後の失敗。手元の
/// リポジトリ（`git-common-dir`）と PR の同一性ごとに 1 つで、アプリが動いている間持つ。PR のパネル・PR の diff タブ・
/// タブ行のチェックが同じものを見るので、確認済みが面やウインドウで食い違わない。
///
/// GitHub に問い合わせるのは見ている者（`beginWatching`）がいる間だけ。中身を読み直すきっかけは、誰も見ていない状態から
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
  struct DiffEnds: Equatable {
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

  /// 最後の失敗。次の読み直し・確認済みの書き込みで消える。
  enum Failure: Equatable {
    case read(GitHubFailure)
    case write(GitHubFailure)
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
  /// 最後に読めた中身。
  private(set) var content: GitHubPullRequestContent?
  var failure: Failure?
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
    if isWatched { observe() }
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

  /// 中身を読み直す（見ている者がいるときだけ）。両端が求まらなかったなら、求め直す。
  func reload() {
    guard isWatched else { return }
    if case .failed = bounds { bounds = .none }
    guard !isReading else {
      readAgain = true
      return
    }
    isReading = true
    failure = nil
    let order = issueOrder()
    notify()
    // 問い合わせる前の追跡 ref の値を覚えてから問い合わせる（→ worktree の今の PR と同じ）。
    tracking.record { [weak self] in self?.readContent(order: order) }
  }

  private func readContent(order: Int) {
    source.content(key.id) { [weak self] result in
      guard let self else { return }
      isReading = false
      switch result {
      case .success(let read):
        apply(read, order: order)
        // 中身が読めて追跡 ref が新しく分かったら、その値も覚える。
        if trackedRefs.contains(where: tracking.lacks) { tracking.record() }
      case .failure(let reason): failure = .read(reason)
      }
      if readAgain {
        readAgain = false
        reload()
      }
      resolveBounds()
      notify()
    }
  }

  /// 出した順の通し番号を 1 つ出す。
  func issueOrder() -> Int {
    nextOrder += 1
    return nextOrder
  }

  /// 読めた中身を入れる。確認済みは、その読み直しより後に出した書き込みで決まったパスでは上書きしない。
  private func apply(_ read: GitHubPullRequestContent, order: Int) {
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
        let fetched: (GitWriteFailure?) -> Void = { [weak self] _ in
          self?.mergeBase(ends, in: repo, fetched: true)
        }
        repo.fetch(
          commits: [ends.base, ends.head], from: remote, handle: GitRunner.Handle(),
          completion: fetched)
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
