import Foundation

/// worktree 作成先（設定パレットの textInput 編集面）ドメインの文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let worktreePathTable: [L10nKey: (ja: String, en: String)] = [
    .settingsWorktreePath: ("Worktree の作成先", "Worktree Location"),
    .settingsWorktreePathBreadcrumb: ("‹ Worktree の作成先", "‹ Worktree location"),
    .settingsWorktreePathPlaceholder: (
      "例: ../{repo}-worktrees/{slug}", "e.g. ../{repo}-worktrees/{slug}"
    ),
    .settingsWorktreePathHint: ("↵ 設定   esc 戻る", "↵ Set   esc Back"),
    .settingsWorktreePathPreview: ("作成先 → %@", "Creates at → %@"),
    .settingsWorktreePathErrEmpty: ("テンプレートを入力してください", "Enter a template"),
    .settingsWorktreePathErrMissingSlug: (
      "{slug} を含めてください（無いと全 worktree が衝突します）",
      "Include {slug} (otherwise all worktrees collide)"
    ),
    .settingsWorktreePathErrUnknownToken: (
      "未知のトークン {%@}（使えるのは {repo} と {slug}）",
      "Unknown token {%@} (only {repo} and {slug})"
    ),
  ]
}
