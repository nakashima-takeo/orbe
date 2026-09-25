import Foundation

/// Dispatch が前回取得した gh 結果をリポジトリ単位で保持する置き場であり、open 一覧取得の合流点。
/// 前回結果は次に開いたときの先描き（stale-while-revalidate）の元になる。保存先はこの型に閉じており、
/// ディスク永続へ移す場合もここの中だけを差し替える。
///
/// 一覧取得は数秒かかりうるので、パレットより長生きする。取得の持ち主をパレット 1 回分ではなく
/// リポジトリ単位のここに置くことで、同じリポジトリ・同じ種別の取得は常に 1 本になる——取得中に
/// 開き直したパレットは取り直さずその着地を受け取り、古い取得が新しい結果を上書きする順序も生まれない。
/// キーは `GitRepo.commonDir`（worktree 間で共有される唯一の識別子。issue/PR はリポジトリ全体の話）。
/// メインスレッド専用（`DispatchDataProvider` の全メソッドと `GitHubCLI` の completion がメインで返る
/// 契約に乗るため、ロックは張らない）。
final class DispatchGitHubCache {
  static let shared = DispatchGitHubCache()

  /// `issues` / `pullRequests` は `nil` = 未取得（`[]` は 0 件）。GitHubCLI の境界と同じ区別を
  /// ここでも保つ。
  struct Entry {
    var issues: [GitHubIssue]?
    var pullRequests: [GitHubPullRequest]?
    /// head → その head の PR。**キーが無い＝未取得**（`[]` は 0 件）。区別を head 単位に保つ
    /// ——1 本の失敗が、他の head の先描きを消さない。
    var branchPullRequests: [String: [GitHubBranchPR]] = [:]
  }

  private var entries: [String: Entry] = [:]
  /// 取得中の open 一覧の受け手（種別ごと。キーがあれば取得中）。
  private var issueWaiters: [String: [([GitHubIssue]?) -> Void]] = [:]
  private var pullRequestWaiters: [String: [([GitHubPullRequest]?) -> Void]] = [:]

  func entry(for key: String) -> Entry? { entries[key] }

  /// 各レーンは独立に到着し独立に失敗しうるので setter を分ける（片方の失敗が他方を巻き込まない）。
  func setIssues(_ issues: [GitHubIssue], for key: String) {
    entries[key, default: Entry()].issues = issues
  }

  func setPullRequests(_ pullRequests: [GitHubPullRequest], for key: String) {
    entries[key, default: Entry()].pullRequests = pullRequests
  }

  /// open issue 一覧を取り直し、着地を `landed` へ届ける。同じリポジトリの取得が進行中なら `fetch` は
  /// 撃たずその着地を待つ。成功はキャッシュへ書いてから届け、失敗（`nil`）は書かずに届ける。
  /// キャッシュ書き込みは受け手の生死に依らない——受け手（provider）はパレットと同じ寿命で、
  /// 着地前に閉じられるのが常用経路。受け手が消えたら捨てる作りだと次回の先描きが永遠に温まらない。
  func refreshIssues(
    for key: String, fetch: (@escaping ([GitHubIssue]?) -> Void) -> Void,
    landed: @escaping ([GitHubIssue]?) -> Void
  ) {
    join(\.issueWaiters, key: key, fetch: fetch, landed: landed) { self.setIssues($0, for: key) }
  }

  /// open PR 一覧の取り直し。規則は `refreshIssues` と同じ（片方の取得が他方を巻き込まないよう種別で分ける）。
  func refreshPullRequests(
    for key: String, fetch: (@escaping ([GitHubPullRequest]?) -> Void) -> Void,
    landed: @escaping ([GitHubPullRequest]?) -> Void
  ) {
    join(\.pullRequestWaiters, key: key, fetch: fetch, landed: landed) {
      self.setPullRequests($0, for: key)
    }
  }

  /// 合流の規則。進行中なら受け手を足すだけ、でなければ取得を始める。着地は ① 成功ならキャッシュへ
  /// 書く → ② 受け手の列を取り出して空にする → ③ 配る、の順——受け手の中から同じ種別の取り直しが
  /// 来ても、キャッシュは着地済みで、取り直しは新しい取得として始まる。
  private func join<T>(
    _ waiters: ReferenceWritableKeyPath<DispatchGitHubCache, [String: [(T?) -> Void]]>,
    key: String, fetch: (@escaping (T?) -> Void) -> Void, landed: @escaping (T?) -> Void,
    store: @escaping (T) -> Void
  ) {
    if self[keyPath: waiters][key] != nil {
      self[keyPath: waiters][key]?.append(landed)
      return
    }
    self[keyPath: waiters][key] = [landed]
    fetch { result in
      if let result { store(result) }
      let receivers = self[keyPath: waiters].removeValue(forKey: key) ?? []
      for receiver in receivers { receiver(result) }
    }
  }

  /// ブランチの PR は head 単位で到着し head 単位で失敗するので、保存も head 単位。
  func setBranchPullRequests(_ pullRequests: [GitHubBranchPR], head: String, for key: String) {
    entries[key, default: Entry()].branchPullRequests[head] = pullRequests
  }
}
