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

/// worktree パレット（⌘⇧X）が表示する 1 行。実データ（worktree/branch）と実行ペイロードを持つ。
/// 色や強調は種別＋`isPrimary` から View が導く。
struct WorktreePaletteItem: Identifiable {
  /// 先頭グリフ列の種別（見た目とグリフ色を決める）。
  enum Glyph { case worktree, localBranch, remoteBranch, clean }

  let id = UUID()
  /// 先頭グリフ。
  var glyph: Glyph
  let name: String
  /// 名前の後に muted で出す補足（worktree の `~/wt/… · branch`・branch の `1d前` 等）。nil で出さない。
  var detail: String?
  /// `detail` を言語別に引くキー（実データ由来でない固定文言の行）。View が引き、`detail` に優先する。
  var detailKey: L10nKey?
  /// 名前・補足のほかに絞り込みへ効かせる別名（`clean` 行の `rm` / `prune` / `掃除`）。
  var aliases: [String] = []
  /// clean 行の候補件数（safe 群の件数）。nil で行末バッジを出さない（0 件でも行そのものは残る）。
  var candidateCount: Int?
  /// worktree の working リング（10×10）を右端に出すか。
  var showsWorkingIndicator = false
  /// Local branch 行の upstream との差（右端の `↑N` / `↓N` ピル）。着地前・同期済み・upstream 無しは nil。
  var sync: WorktreePaletteBranchSync?
  /// アクティブ worktree（グリフ=working 色・名前=chromeText）。他行は muted/secondary。
  var isPrimary = false
  /// 決定（↵／行タップ）のペイロード。
  var action: WorktreePaletteAction
  /// フッターに出す実行説明（選択に連動して差し替わる）。
  var footer: WorktreePaletteFooter
}

/// 選択行に連動するフッターの中身。
enum WorktreePaletteFooter: Equatable {
  /// 実行説明。`↵ <target> <前置> <agent> を新しいタブで起動` の骨。前置句は worktree 解決種別から、
  /// agent 名は選択中 agent（動的）を、後置句は共通キーを View が言語別に挿す（Japanese 断片の連結を排す）。
  case launch(target: String, kind: WorktreeOpenKind)
  /// 注記のみ（実行説明もキーヒントも出さない行）。
  case note(L10nKey)
}

/// 見出し（選択対象外）と行の束。
struct WorktreePaletteSection: Identifiable {
  let title: String
  var items: [WorktreePaletteItem]
  var id: String { title }
}
