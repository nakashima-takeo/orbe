import Foundation

// worktree パレットの行の値型。組み立ては `WorktreePaletteSectionBuilder`、描画は `WorktreePaletteRows`。

/// Local branch 行の upstream との同期（提示時の `fetch --prune` が着地した後の値）。
/// 立つのは**信頼する remote（origin）を追跡する行だけ**——worktree パレットは prune も到達性も origin だけを
/// 信頼しており、他 remote の upstream は裏 fetch で鮮度が担保されない。
struct WorktreePaletteBranchSync: Equatable {
  let name: String
  /// 表示は `short`、最新化の実行は `remote` / `remoteRef` / `ref`。
  let upstream: GitUpstream
  let ahead: Int
  let behind: Int

  /// 最新化の選択画面に入る唯一の条件。分岐（↑↓）・↑ だけ・同期済みは即作成。
  var isFastForwardable: Bool { ahead == 0 && behind > 0 }

  /// 鮮度を信頼する remote（提示時に fetch する唯一の remote）。
  static let trustedRemote = "origin"

  /// 信頼する remote を追跡しているか。track は問わない——着地前に「着地を待つべき行か」を決める述語で、
  /// ピル・選択画面の条件（`init?`）もここを読む。
  static func tracksTrustedRemote(_ branch: GitBranch) -> Bool {
    branch.upstream?.remote == trustedRemote
  }

  /// 同期済み（差が無い）・`[gone]`・信頼しない remote の行は nil。
  init?(_ branch: GitBranch) {
    guard Self.tracksTrustedRemote(branch), let upstream = branch.upstream,
      case .counts(let ahead, let behind) = upstream.track
    else { return nil }
    name = branch.name
    self.upstream = upstream
    self.ahead = ahead
    self.behind = behind
  }
}

/// worktree パレット（⌘T）が表示する 1 行。実データ（worktree/branch）と実行ペイロードを持つ。
/// 色や強調は種別＋`isCurrent` から View が導く。
struct WorktreePaletteItem: Identifiable {
  /// 先頭グリフ列の種別（見た目とグリフ色を決める）。
  enum Glyph { case worktree, directory, localBranch, remoteBranch, pullRequest, newBranch, clean }

  let id = UUID()
  /// 先頭グリフ。
  var glyph: Glyph
  let name: String
  /// `name` を言語別に引くキー（実データ由来でない固定の名前の行）。View が引き、`name` に優先する。
  var nameKey: L10nKey?
  /// 名前の後に muted で出す補足（worktree の `~/wt/…`・branch の `1d前` 等）。nil で出さない。
  var detail: String?
  /// `detail` を言語別に引くキー（実データ由来でない固定文言の行）。View が引き、`detail` に優先する。
  var detailKey: L10nKey?
  /// 名前・補足のほかに絞り込みへ効かせる別名（worktree 行のブランチ名・`clean` 行の `rm` / `prune` / `掃除`）。
  var aliases: [String] = []
  /// clean 行の候補件数（safe 群の件数）。nil で行末バッジを出さない（0 件でも行そのものは残る）。
  var candidateCount: Int?
  /// Local branch 行の upstream との差（右端の `↑N` / `↓N` ピル）。着地前・同期済み・upstream 無しは nil。
  var sync: WorktreePaletteBranchSync?
  /// 今の worktree の行（「現在」の札・入力が空のときの初期選択）。
  var isCurrent = false
  /// 既存のディレクトリを開く行（worktree・「このディレクトリ」）の場所のキー。その場所を持つタスクの札と、
  /// ↵ の付け替えの判定に使う。
  var worktreeKey: String?
  /// PR のブランチの行（タスクの欄。印は `.pullRequest`）の PR の番号。補足に「PR #N のブランチ」を出す。
  var pullRequest: Int?
  /// 決定（↵／行タップ）のペイロード。
  var action: WorktreePaletteAction
  /// ↵ が何をするか（フッターとベースのバーの言葉）。
  var enter: WorktreePaletteEnter
}

extension WorktreePaletteItem {
  /// ベースのバーの「なし — …」。PR のブランチの行は、そのブランチが PR のものだと添える。
  var baseNote: (key: L10nKey, values: [String])? {
    switch (pullRequest, enter) {
    case (let number?, .checkout(let name)), (let number?, .trackRemote(_, let name)):
      (.worktreePaletteBaseNonePullRequest, ["\(number)", name])
    default: enter.baseNote
    }
  }
}

/// 選択行の ↵ が何をするか。フッターの実行説明と、ベースのバーの「なし — …」の言葉の元。
enum WorktreePaletteEnter: Equatable {
  /// 既存の worktree をそのまま開く（対象名）。
  case openWorktree(String)
  /// 非 git のディレクトリをそのまま開く（パス）。
  case openDirectory(String)
  /// 既存のローカルブランチを worktree にして開く（ブランチ名）。
  case checkout(String)
  /// リモートブランチを追跡するローカルブランチを作り、worktree にして開く（リモートの名前・作るローカル名）。
  case trackRemote(remote: String, local: String)
  /// 新しいブランチを、ベースのバーで選んだベースから作って開く（ブランチ名）。
  case create(String)
  /// clean 画面へ入る。
  case clean

  /// ベースのバーの「なし — …」の文言キーと、差し込む値（テンプレートの位置順）。作成行は選択肢の
  /// ボタンを出すので言葉を持たない。
  var baseNote: (key: L10nKey, values: [String])? {
    switch self {
    case .openWorktree: (.worktreePaletteBaseNoneWorktree, [])
    case .openDirectory: (.worktreePaletteBaseNoneDirectory, [])
    case .checkout(let name): (.worktreePaletteBaseNoneCheckout, [name])
    case .trackRemote(let remote, let local):
      (.worktreePaletteBaseNoneTrackRemote, [remote, local])
    case .clean: (.worktreePaletteBaseNoneClean, [])
    case .create: nil
    }
  }
}

/// 見出し（選択対象外）と行の束。
struct WorktreePaletteSection: Identifiable {
  /// 見出しの種類。文言は View が言語別に引く。
  enum Title: Hashable {
    case newBranch
    /// リポジトリ名を添えた worktree の欄。
    case worktrees(repository: String)
    case branches
    /// 絞り込みで既存の行が 0 件になったときの注記の見出し。
    case worktreesAndBranches
    /// タスクから開いたときの先頭の欄（「#221 の worktree」。主が無ければ番号は nil）。
    case task(number: Int?)
  }

  /// nil は見出しを出さない（非 git の「このディレクトリ」だけの一覧）。
  let title: Title?
  var items: [WorktreePaletteItem]
  /// 行が 0 件のときに見出しの下に出す注記。
  var emptyNote: L10nKey?

  init(title: Title?, items: [WorktreePaletteItem], emptyNote: L10nKey? = nil) {
    self.title = title
    self.items = items
    self.emptyNote = emptyNote
  }

  var id: String {
    switch title {
    case .newBranch: "newBranch"
    case .worktrees: "worktrees"
    case .branches: "branches"
    case .worktreesAndBranches: "worktreesAndBranches"
    case .task: "task"
    case nil: "untitled"
    }
  }

  func with(items: [WorktreePaletteItem]) -> WorktreePaletteSection {
    WorktreePaletteSection(title: title, items: items, emptyNote: emptyNote)
  }
}
