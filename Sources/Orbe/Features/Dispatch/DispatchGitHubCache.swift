import Foundation

/// Dispatch が前回取得した gh 結果をリポジトリ単位で保持する置き場であり、open 一覧取得の合流点。
/// 前回結果は次に開いたときの先描き（stale-while-revalidate）の元になる。保存先はこの型に閉じており、
/// ディスク永続へ移す場合もここの中だけを差し替える。
///
/// open 一覧はページが届くたびに伸び、上限まで取り終えるのに数十秒かかりうるので、取得はパレットより
/// 長生きする。取得の持ち主をパレット 1 回分ではなくリポジトリ単位のここに置くことで、同じリポジトリ・
/// 同じ種別の取得は常に 1 本になり、パレットを閉じても上限まで続いてキャッシュが育つ。一覧を組み立てる
/// のもここだけで、受け手には常にキャッシュの現在値を配る。
/// キーは `GitRepo.commonDir`（worktree 間で共有される唯一の識別子。issue/PR はリポジトリ全体の話）。
/// メインスレッド専用（`DispatchDataProvider` の全メソッドと `GitHubCLI` の completion がメインで返る
/// 契約に乗るため、ロックは張らない）。
final class DispatchGitHubCache {
  static let shared = DispatchGitHubCache()

  /// `issues` / `pullRequests` は `nil` = 未取得（`[]` は 0 件）。
  struct Entry {
    var issues: [GitHubIssue]?
    var pullRequests: [GitHubPullRequest]?
    /// head → その head の PR。**キーが無い＝未取得**（`[]` は 0 件）。区別を head 単位に保つ
    /// ——1 本の失敗が、他の head の先描きを消さない。
    var branchPullRequests: [String: [GitHubBranchPR]] = [:]
    /// remote の URL から読んだ名前 → GitHub の答え。**キーが無い＝まだ答えを得ていない**。
    /// `.unverified` も書く——次に開いたときは最初のフレームからその扱いで描き、裏で問い直す。
    var repositoryNames: [GitHubRepoName: GitHubRepositoryResolution] = [:]
  }

  private var entries: [String: Entry] = [:]
  /// 進行中の open 一覧の取り直し（種別ごと。キーがあれば取得中）。
  private var issueRefreshes: [String: Refresh<GitHubIssue>] = [:]
  private var pullRequestRefreshes: [String: Refresh<GitHubPullRequest>] = [:]

  /// 1 本の取り直しの状態。
  private struct Refresh<T> {
    /// 開始時点のキャッシュ。まだ届いていない古い範囲をこれで埋める。
    let previous: [T]?
    /// 今回届いた分。
    var fresh: [T] = []
    /// 一覧の現在値（`nil` = 未取得）と、取得中かを受け取る受け手。
    var receivers: [([T]?, Bool) -> Void]
  }

  func entry(for key: String) -> Entry? { entries[key] }

  /// open issue 一覧を取り直し、そのたびの現在値を `updated` へ届ける。`fetch` はページを `page` へ、
  /// 終わりを `finished`（`true` = 取り終えた／`false` = 途中で失敗）へ渡す取得（`GitHubCLI.openIssues`）。
  /// 受け手の生死に依らずキャッシュを書くので、パレットを閉じても上限まで取り続ける。
  func refreshIssues(
    for key: String,
    fetch: (_ page: @escaping ([GitHubIssue]) -> Void, _ finished: @escaping (Bool) -> Void) ->
      Void,
    updated: @escaping ([GitHubIssue]?, _ growing: Bool) -> Void
  ) {
    refresh(\.issueRefreshes, \.issues, key: key, fetch: fetch, updated: updated)
  }

  /// open PR 一覧の取り直し。規則は `refreshIssues` と同じ（片方の取得が他方を巻き込まないよう種別で分ける）。
  func refreshPullRequests(
    for key: String,
    fetch: (_ page: @escaping ([GitHubPullRequest]) -> Void, _ finished: @escaping (Bool) -> Void)
      -> Void,
    updated: @escaping ([GitHubPullRequest]?, _ growing: Bool) -> Void
  ) {
    refresh(\.pullRequestRefreshes, \.pullRequests, key: key, fetch: fetch, updated: updated)
  }

  /// 合流と組み立ての規則。受け手は登録した時点で現在値を 1 回受け取る——取得の途中で合流しても、
  /// それまでに届いたページを取りこぼさない。同じリポジトリ・種別の取得が進行中なら `fetch` は撃たない。
  /// - ページ: 今回分に足し、`merge` した一覧をキャッシュへ書いて全員に配る。
  /// - 完了: 今回分でキャッシュを置き換える。
  /// - 失敗: キャッシュはそれまでに書いたまま（届いた範囲＋前回の残り）。
  /// 完了・失敗は ① キャッシュを確定 → ② 受け手の列を取り出して空にする → ③ 配る、の順——受け手の中から
  /// 同じ種別の取り直しが来ても、それは新しい取得として始まる。
  private func refresh<T: GitHubNumbered>(
    _ refreshes: ReferenceWritableKeyPath<DispatchGitHubCache, [String: Refresh<T>]>,
    _ list: WritableKeyPath<Entry, [T]?>, key: String,
    fetch: (@escaping ([T]) -> Void, @escaping (Bool) -> Void) -> Void,
    updated: @escaping ([T]?, Bool) -> Void
  ) {
    let current = entries[key]?[keyPath: list]
    if self[keyPath: refreshes][key] != nil {
      self[keyPath: refreshes][key]?.receivers.append(updated)
      updated(current, true)
      return
    }
    self[keyPath: refreshes][key] = Refresh(previous: current, receivers: [updated])
    updated(current, true)
    fetch(
      { nodes in
        guard var refresh = self[keyPath: refreshes][key] else { return }
        refresh.fresh += nodes
        self[keyPath: refreshes][key] = refresh
        let merged = Self.merge(fresh: refresh.fresh, previous: refresh.previous)
        self.entries[key, default: Entry()][keyPath: list] = merged
        for receiver in refresh.receivers { receiver(merged, true) }
      },
      { succeeded in
        guard let refresh = self[keyPath: refreshes][key] else { return }
        if succeeded { self.entries[key, default: Entry()][keyPath: list] = refresh.fresh }
        self[keyPath: refreshes][key] = nil
        let settled = self.entries[key]?[keyPath: list]
        for receiver in refresh.receivers { receiver(settled, false) }
      })
  }

  /// 取り直し途中の一覧。今回届いた分の後ろに、前回の一覧のうち「今回分に含まれる要素で前回の並びの
  /// 一番後ろにあるもの」より後ろをつなぐ（重ならなければ前回を全部つなぐ）。境目は前回の並び順だけで
  /// 決める——番号が作成順に振られている前提を置くと、移された issue で崩れる。
  static func merge<T: GitHubNumbered>(fresh: [T], previous: [T]?) -> [T] {
    guard let previous else { return fresh }
    let numbers = Set(fresh.map(\.number))
    let rest = previous.lastIndex { numbers.contains($0.number) }.map { $0 + 1 } ?? 0
    return fresh + previous[rest...]
  }

  /// 正式名は remote ごとに問い合わせて届くので、保存も読んだ名前の単位。
  func setRepositoryName(
    _ resolution: GitHubRepositoryResolution, for name: GitHubRepoName, key: String
  ) {
    entries[key, default: Entry()].repositoryNames[name] = resolution
  }

  /// ブランチの PR は head 単位で到着し head 単位で失敗するので、保存も head 単位。
  func setBranchPullRequests(_ pullRequests: [GitHubBranchPR], head: String, for key: String) {
    entries[key, default: Entry()].branchPullRequests[head] = pullRequests
  }
}
