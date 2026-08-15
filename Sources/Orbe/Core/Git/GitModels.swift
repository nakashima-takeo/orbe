import Foundation

// MARK: - worktree / branch（Dispatch パレット）

/// `git worktree list --porcelain` の 1 チェックアウト。
struct GitWorktree: Equatable {
  /// worktree の絶対パス。
  let path: String
  /// チェックアウト中のブランチ（`refs/heads/` を落とした短縮名）。detached なら nil。
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

/// `git for-each-ref` の 1 ブランチ（local / remote 兼用）。
struct GitBranch: Equatable {
  /// 短縮名（local は `feat/x`・remote は `origin/feat/x`）。
  let name: String
  /// local は相対コミット日時（`1d前`）。remote は `author · 相対日時`。
  let relativeDate: String
  /// このブランチが既にチェックアウトされている worktree の絶対パス（`worktreepath`）。無ければ nil。
  let worktreePath: String?
  /// upstream の短縮名（`origin/x`）。無ければ nil。
  let upstream: String?
  /// `%(upstream:track)`（`[gone]` / `[ahead 1]` 等）。空なら nil。
  var track: String?
}

// MARK: - GitHub（gh CLI）

/// `gh issue list --json number,title` の 1 issue。
struct GitHubIssue: Decodable, Equatable {
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

/// `gh pr list --json number,title,headRefName,reviewDecision,isCrossRepository` の 1 PR。
struct GitHubPullRequest: Decodable, Equatable {
  let number: Int
  let title: String
  let headRefName: String
  /// `REVIEW_REQUIRED` / `APPROVED` / `CHANGES_REQUESTED` / null。
  let reviewDecision: String?
  /// fork（cross-repo）由来の PR か。head ref がローカルに無いことがある。
  let isCrossRepository: Bool
}
