import Foundation

// MARK: - worktree / branch（Dispatch パレット）

/// `git worktree list --porcelain` の 1 チェックアウト。
struct GitWorktree: Equatable {
  /// worktree の絶対パス。
  let path: String
  /// チェックアウト中のブランチ（`refs/heads/` を除いた正確な名前）。detached なら nil。
  let branch: String?
  /// HEAD の oid。
  let head: String
  /// 本体（main）worktree か。worktree 作成先の親ディレクトリ導出に使う。
  let isMain: Bool
  /// porcelain の `prunable <reason>` 行。ディスク上の実体が失われている（掃除の推定材料）。
  var isPrunable = false
  /// porcelain の `locked [reason]` 行の理由（理由が無ければ空文字）。locked でなければ nil。
  var lockReason: String?
}

/// `git worktree add -b` で切る新規ブランチ。追跡の指定（`--track` / `--no-track`）は git が
/// 新規ブランチにだけ許すので、名前と 1 つの値にまとめて「既存ブランチの checkout には付かない」を
/// 型で表す。
struct GitNewBranch: Equatable {
  let name: String
  /// base を upstream として追跡するか。
  let tracksBase: Bool
}

/// upstream との同期（`%(upstream:track)` を解釈した値）。同期済みは `GitUpstream.track` の nil。
enum GitUpstreamTrack: Equatable {
  /// upstream がリモートで消えている（`[gone]`）。
  case gone
  /// `[ahead N]` / `[behind M]` / `[ahead N, behind M]`。出ない側は 0。
  case counts(ahead: Int, behind: Int)
}

/// ローカルブランチの upstream。`for-each-ref` の upstream 系フィールドを 1 回だけ解釈した値で、
/// 表示（`short`）も最新化の git コマンド（`remote` / `remoteRef` / `ref`）もここから組む。
struct GitUpstream: Equatable {
  /// `%(upstream:short)`（`origin/x`。表示用）。
  let short: String
  /// `%(upstream)`（`refs/remotes/origin/x`。追跡 ref）。
  let ref: String
  /// `%(upstream:remotename)`（`origin`）。
  let remote: String
  /// `%(upstream:remoteref)`（`refs/heads/x`。remote 側の ref）。
  let remoteRef: String
  /// `%(upstream:track)`。nil は同期済み。
  let track: GitUpstreamTrack?
}

/// `git for-each-ref` の 1 ブランチ（local / remote 兼用）。
struct GitBranch: Equatable {
  /// `refs/heads/` / `refs/remotes/` を除いた正確な名前（local は `feat/x`・remote は `origin/feat/x`）。
  let name: String
  /// local は相対コミット日時（`1d前`）。remote は `author · 相対日時`。
  let relativeDate: String
  /// upstream。無ければ nil（remote ブランチは常に nil）。
  let upstream: GitUpstream?
}

// MARK: - GitHub（gh CLI）

/// 番号で同一性を持つ GitHub の項目。open 一覧を取り直す途中、前回の一覧との境目を探すのに使う。
protocol GitHubNumbered {
  var number: Int { get }
}

/// GraphQL の connection 1 ページ（`nodes` ＋ `pageInfo`）。
struct GitHubPage<Node: Decodable>: Decodable {
  struct PageInfo: Decodable {
    let hasNextPage: Bool
    /// 次のページの位置。ページが空なら nil。
    let endCursor: String?
  }

  let nodes: [Node]
  let pageInfo: PageInfo
}

/// open issue 一覧（GraphQL `issues`）の 1 issue。
struct GitHubIssue: Decodable, Equatable, GitHubNumbered {
  let number: Int
  let title: String
}

/// `gh pr list --state all --head <branch> --json number,headRefName,state,baseRefName,isCrossRepository`
/// の 1 PR。worktree の掃除で「レビュー中か／マージ済みか／未マージのまま閉じられたか」を見るための
/// 小さな形で、`GitHubPullRequest`（title 必須）ではこの JSON をデコードできない。
struct GitHubBranchPR: Decodable, Equatable {
  let number: Int
  let headRefName: String
  /// `OPEN` / `MERGED` / `CLOSED`。
  let state: String
  /// マージ先ブランチ。**表示専用**（安全判定はローカル git の事実だけで閉じる）。
  let baseRefName: String
  /// head 側のリポジトリが、gh の解決した base リポジトリと別か。`--head` はブランチ名でしか
  /// 絞れず他人の fork の同名ブランチに立った PR も返るので、突き合わせの足切りに使う。
  ///
  /// **「他人の fork か」と厳密には一致しない。** gh は非対話時、base リポジトリを remote 名の
  /// 優先順（`upstream` > `github` > `origin`）で選ぶ。fork を clone して `upstream` を張った形では
  /// base が upstream になり、**自分の fork に立てた自分の PR も真になる**——その形では merged
  /// チップとマージ済みの推定が出なくなる（安全確認は落ちる方向なので、消えて困るものは残る）。
  let isCrossRepository: Bool
}

/// open PR 一覧（GraphQL `pullRequests`）の 1 PR。
struct GitHubPullRequest: Decodable, Equatable, GitHubNumbered {
  let number: Int
  let title: String
  let headRefName: String
  /// `REVIEW_REQUIRED` / `APPROVED` / `CHANGES_REQUESTED` / null。
  let reviewDecision: String?
  /// fork（cross-repo）由来の PR か。head ref がローカルに無いことがある。
  let isCrossRepository: Bool
}
