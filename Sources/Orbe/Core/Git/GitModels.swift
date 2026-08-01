import Foundation

// MARK: - status

/// 1 ファイルの変更状態（`git status --porcelain=v2` 由来）。
struct FileChange: Equatable {
  enum Status: Equatable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case unmerged
    case untracked
  }

  /// repo root 相対パス（rename 後の現パス）。
  let path: String
  /// rename/copy 元のパス。
  let oldPath: String?
  /// HEAD ↔ index の変更（staged 側）。無ければ nil。
  let staged: Status?
  /// index ↔ worktree の変更（unstaged 側）。無ければ nil。
  let unstaged: Status?

  var isConflicted: Bool { staged == .unmerged || unstaged == .unmerged }
}

/// リポジトリ全体の変更スナップショット。
struct RepoStatus: Equatable {
  /// チェックアウト中のブランチ名。detached HEAD なら nil。
  let branch: String?
  /// HEAD のコミット oid。unborn（初回コミット前）なら nil。
  let oid: String?
  /// upstream ブランチ名（`# branch.upstream`）。未設定なら nil。
  let upstream: String?
  /// upstream に対する先行/後行コミット数（`# branch.ab`）。upstream 不在なら nil。
  let ahead: Int?
  let behind: Int?
  let files: [FileChange]
}

// MARK: - diff

/// 1 ファイル分の差分（unified diff 由来）。
struct FileDiff: Equatable {
  /// 旧側パス。新規ファイル（/dev/null）なら nil。
  let oldPath: String?
  /// 新側パス。削除ファイル（/dev/null）なら nil。
  let newPath: String?
  let isBinary: Bool
  let oldMode: String?
  let newMode: String?
  /// rename/copy の類似度（%）。rename でなければ nil。
  let similarity: Int?
  let hunks: [Hunk]

  var displayPath: String { newPath ?? oldPath ?? "?" }
  var isNew: Bool { oldPath == nil }
  var isDeleted: Bool { newPath == nil }
  var isRenamed: Bool { oldPath != nil && newPath != nil && oldPath != newPath }
}

struct Hunk: Equatable {
  let oldStart: Int
  let oldCount: Int
  let newStart: Int
  let newCount: Int
  /// `@@ ... @@` の後ろに付く関数名等の見出し。無ければ空。
  let sectionHeading: String
  let lines: [DiffLine]
}

struct DiffLine: Equatable {
  enum Kind: Equatable {
    case context
    case removed
    case added
  }

  let kind: Kind
  /// 先頭の `+`/`-`/空白を除いた本文（改行なし）。
  let text: String
  /// この行の直後に `\ No newline at end of file` が続いた。
  let noNewlineAtEnd: Bool
  /// 旧側の行番号（kind == .added なら nil）。
  let oldLine: Int?
  /// 新側の行番号（kind == .removed なら nil）。
  let newLine: Int?

  init(
    kind: Kind, text: String, noNewlineAtEnd: Bool = false,
    oldLine: Int? = nil, newLine: Int? = nil
  ) {
    self.kind = kind
    self.text = text
    self.noNewlineAtEnd = noNewlineAtEnd
    self.oldLine = oldLine
    self.newLine = newLine
  }
}

// MARK: - 部分ステージング

/// FileDiff 内の 1 行を指す参照（hunk 配列の index と hunk 内 lines の index）。
struct LineRef: Hashable {
  let hunk: Int
  let line: Int

  init(_ hunk: Int, _ line: Int) {
    self.hunk = hunk
    self.line = line
  }
}

/// パッチ再構成の方向。非選択変更の正規化規則が方向で反転する:
/// - stage（index へ forward apply。元 diff は index↔worktree）:
///   非選択 removed → context（index に実在し残る）／非選択 added → 落とす（index に無い）
/// - unstage（index へ reverse apply。元 diff は HEAD↔index）:
///   非選択 added → context（index に実在し残る）／非選択 removed → 落とす（index に無い）
enum PatchDirection {
  case stage
  case unstage
}

// MARK: - log

/// `git log` の 1 コミット。
struct Commit: Equatable {
  let oid: String
  let shortOid: String
  let author: String
  let date: Date
  /// 親コミットの oid（`%P`・スペース区切り）。マージ判定と first-parent 連鎖に使う。
  let parents: [String]
  /// この commit を指す ref 装飾（`%D`・カンマ区切りの各要素。例: "HEAD -> main"・"origin/main"・"tag: v1"）。
  let refs: [String]
  let subject: String
}

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
}

// MARK: - GitHub（gh CLI）

/// `gh issue list --json number,title` の 1 issue。
struct GitHubIssue: Decodable, Equatable {
  let number: Int
  let title: String
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
