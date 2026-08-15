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

/// `gh pr list --state closed --json number,headRefName,state` の 1 PR。
/// worktree の掃除で「マージ済みか／未マージのまま閉じられたか」を見るためだけの小さな形で、
/// `GitHubPullRequest`（title・isCrossRepository 必須）ではこの JSON をデコードできない。
struct GitHubClosedPR: Decodable, Equatable {
  let number: Int
  let headRefName: String
  /// `MERGED` / `CLOSED`。
  let state: String
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
