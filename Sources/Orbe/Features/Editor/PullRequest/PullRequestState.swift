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
/// GitHub に問い合わせるのは見ている者（`beginWatching`）がいる間だけで、`reload` で中身を読み直す（見ている者が現れたときと、
/// 読み直すきっかけで呼ばれる）。読んでいる間に次の読み直しが来たら、終わった後に 1 回だけ読み直す。読み直しに失敗しても、
/// 前に読めた中身は残す。
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
    /// PR のコミットが手元に無く、取りに行っても揃わない。
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
  /// git に問い合わせるリポジトリと、PR のコミットを取りに行く remote（PR が置かれたリポジトリを指す remote）。worktree の
  /// 今の PR が結ぶ。
  @ObservationIgnored private(set) var repo: GitRepo?
  @ObservationIgnored private(set) var fetchRemote: String?
  /// 最後に読めた中身。
  private(set) var content: GitHubPullRequestContent?
  var failure: Failure?
  private(set) var isReading = false
  private(set) var bounds = Bounds.none

  /// 確認済みの GitHub の値（パス → 値）と、その値を決めた問い合わせの通し番号。
  var viewed: [String: Bool] = [:]
  @ObservationIgnored var viewedOrder: [String: Int] = [:]
  /// 書いている途中・書く順番を待っている値（パス → 値と、その書き込みの通し番号）。
  var pendingViewed: [String: PendingViewed] = [:]
  @ObservationIgnored var writes: [ViewedWrite] = []
  @ObservationIgnored var isWriting = false
  /// 読み直しと書き込みに付ける、出した順の通し番号。
  @ObservationIgnored private var nextOrder = 0

  @ObservationIgnored private var watchers = 0
  @ObservationIgnored private var rereadQueued = false
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

  /// git に問い合わせるリポジトリと、コミットを取りに行く remote を結ぶ。結んだ後に両端を求められるなら求める。
  func attach(repo: GitRepo, fetchRemote: String?) {
    self.repo = repo
    self.fetchRemote = fetchRemote
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

  /// 見ている者が現れた（中身の読み直しは、誰も見ていなかったときに見始めた者が `reload` で頼む）。
  func beginWatching() {
    watchers += 1
  }

  func endWatching() {
    watchers = max(0, watchers - 1)
  }

  var isWatched: Bool { watchers > 0 }

  // MARK: - 中身

  /// 中身を読み直す（見ている者がいるときだけ）。両端が求まらなかったなら、求め直す。
  func reload() {
    guard isWatched else { return }
    if case .failed = bounds { bounds = .none }
    guard !isReading else {
      rereadQueued = true
      return
    }
    isReading = true
    failure = nil
    let order = issueOrder()
    notify()
    source.content(key.id) { [weak self] result in
      guard let self else { return }
      isReading = false
      switch result {
      case .success(let read): apply(read, order: order)
      case .failure(let reason): failure = .read(reason)
      }
      if rereadQueued {
        rereadQueued = false
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
      case .failed:
        bounds = .failed(ends, .unreadable)
        notify()
      }
    }
  }
}
