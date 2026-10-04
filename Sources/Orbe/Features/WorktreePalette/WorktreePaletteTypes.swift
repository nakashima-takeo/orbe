import Foundation

/// Enter で開く行き先。ディレクトリを解決して（既存の再利用／新規作成）起動する。解決に要る
/// 情報（既存 worktree パス等）を純粋ビルダが焼き込み、実行側（`prepareDirectory`）は分岐するだけにする。
enum WorktreePaletteDestination: Equatable {
  /// 既存のディレクトリをそのまま開く（worktree の行・非 git の「このディレクトリ」の行）。
  case directory(path: String)
  case localBranch(name: String)
  /// name は `origin/x`（`refs/remotes/` を除いた正確な名前）。
  case remoteBranch(name: String, existingWorktree: String?)
  /// base から name の新しいブランチ（upstream なし）を切り、その worktree を作る。
  case newBranch(name: String, base: WorktreeBase)

  /// 作らずにそのまま開く既存のディレクトリ（リモートブランチの行は、そのブランチの worktree があるとき）。
  var existingDirectory: String? {
    switch self {
    case .directory(let path): path
    case .remoteBranch(_, let existing): existing
    case .localBranch, .newBranch: nil
    }
  }
}

/// 新しいブランチを切るベース。既定ブランチは**参照ではなく意図**として持ち、名前の解決を作成の直前まで
/// 遅らせる——提示時に読んだ名前を捕まえると、着地を待つあいだに fetch が `origin/HEAD` を作っても
/// （git の `followRemoteHEAD` 既定）フォールバックの固定名のまま撃ってしまう。
enum WorktreeBase: Equatable {
  case ref(String)
  case defaultBranch
}

/// 決定（↵／行タップ）の対象。外（`onExecute`）へ届くのは行き先だけで、ディレクトリを解決しない行為
/// （clean 画面・ベースを選ぶ画面）はパレットの中で畳む。
enum WorktreePaletteAction: Equatable {
  case open(WorktreePaletteDestination)
  /// 打った名前の新しいブランチ。ベースは行ではなくベースのバーの選択が決める（決定の時点で読む）。
  case createBranch(name: String)
  /// worktree の欄の末尾の `clean` 行。決定でパレット内の clean 画面へ入る。
  case clean
}

/// worktree パレットの中身。器（カード枠・焦点契約・高さ契約）は共通で、中身だけ切り替わる。
enum WorktreePaletteMode: Equatable {
  case list, clean
  /// 遅れた Local branch を最新化してから作るかを選ぶ画面。
  case refresh
  /// 新しいブランチのベースを、ブランチの一覧から選ぶ画面。
  case basePicker
}

/// ⇥ 巡回で選ぶ起動先。解決した worktree で agent を走らせるか、素の shell を開くか。
enum WorktreePaletteTarget: Equatable {
  case agent(AgentCLI)
  case shell

  /// ボタン・フッターに出す名前。agent は raw command、shell はリテラル（技術語で日英同一）。
  var name: String {
    switch self {
    case .agent(let agent): agent.command
    case .shell: "shell"
    }
  }
}
