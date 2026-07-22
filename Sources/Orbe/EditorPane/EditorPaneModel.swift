import Foundation
import Observation
import WebKit

// MARK: - 状態機械（EditorPane のツール・タブ・選択状態）

/// 右ツールレールの3ツール。宣言順は ToolRailView の縦並び順と一致させる
/// （allCases 経由の Cmd+Shift+↑/↓ 上下移動が視覚順と揃う前提）。
enum EditorTool: Hashable, CaseIterable {
  case tree
  case git
  case browser
}

extension EditorTool {
  /// 永続表現（`workspaces.json` の `TabState.editor.tool`）。
  var persistKey: String {
    switch self {
    case .tree: return "tree"
    case .git: return "git"
    case .browser: return "browser"
    }
  }

  init(persistKey: String) {
    switch persistKey {
    case "git": self = .git
    case "browser": self = .browser
    default: self = .tree
    }
  }
}

/// git ツール配下の2サブタブ。
enum GitTab {
  case changes
  case history
}

/// FileViewer の文脈（ツリー閲覧 or git 変更レビュー）。初期ビュー・セグメント・誘導文を分岐する。
enum ViewerCtx {
  case tree
  case changes
}

enum EditorViewMode {
  case file
  case source
  case preview
  case diff
}

/// ファイルの stage 3状態（変更レールの StageBox）。
enum StageState {
  case none
  case partial
  case staged
}

/// 履歴レールの選択。
enum HistorySelection: Equatable {
  /// 先頭の「未コミットの変更」擬似ノード。
  case uncommitted
  case commit(String)
}

/// 変更バッジ（M/A/D/C）。色は view 側で解決する。
enum ChangeBadge {
  case modified
  case added
  case deleted
  case conflict

  var letter: String {
    switch self {
    case .modified: return "M"
    case .added: return "A"
    case .deleted: return "D"
    case .conflict: return "C"
    }
  }

  static func of(_ change: FileChange) -> ChangeBadge {
    if change.isConflicted { return .conflict }
    switch change.unstaged ?? change.staged {
    case .added, .untracked: return .added
    case .deleted: return .deleted
    default: return .modified
    }
  }
}

/// コミットバー近傍の最小表示（コミット失敗/成功）。
enum PaneBanner: Equatable {
  case success(String)
  case error(String)
}

/// 1 タブ分の EditorPane UI 状態（タブ＝TerminalController が所有）。retarget・FSEvents 再描画・
/// タブ切替をまたいで保持される。
@Observable final class EditorPaneUIState {
  /// 本体パネル（tree/git/browser の中身）を開いているか。false でもレールは残る。
  var paneOpen = false
  var tool: EditorTool = .tree
  var gitTab: GitTab = .changes
  var viewMode: EditorViewMode = .file
  var selectedPath: String?
  /// ツリーのフォルダ開閉の明示上書き（既定: 全フォルダ閉）。
  var treeFolderOpen: [String: Bool] = [:]
  /// 変更レールのフォルダ開閉の明示上書き（既定: 開）。
  var changesFolderOpen: [String: Bool] = [:]
  /// 折りたたんだ hunk のキー（`PaneMergedHunk.id`）。
  var collapsedHunks: Set<String> = []
  var commitDraft = ""
  /// 履歴の選択。nil = 自動（未コミットノードがあればそれ・無ければ先頭コミット）。
  var selectedCommit: HistorySelection?
}

/// EditorPane から届く操作。実装は EditorPaneController（git 操作の唯一の入口）。
protocol EditorPaneActions: AnyObject {
  func stageFile(_ change: FileChange)
  func unstageFile(_ change: FileChange)
  /// フォルダ単位の一括 stage/unstage（conflict は除外）。
  func stageFiles(_ changes: [FileChange])
  func unstageFiles(_ changes: [FileChange])
  /// 変更破棄（worktree を書く確定操作）。tracked は index へ戻し untracked は削除する。
  func discardFiles(_ changes: [FileChange])
  func stageHunk(path: String, diff: FileDiff, hunkIndex: Int, untracked: Bool)
  func unstageHunk(path: String, diff: FileDiff, hunkIndex: Int)
  func commit(message: String)
  func loadMoreHistory()
  func selectHistory(_ selection: HistorySelection)
  func copyToPasteboard(_ text: String)
  func focusTerminal()
  /// 埋め込みブラウザのナビゲーション（controller が WKWebView を操作する）。
  func browserGoBack()
  func browserGoForward()
  func browserReload()
  /// 現在 URL を既定ブラウザで開く。
  func openBrowserExternally()
  /// browser ツールへ切替えた（dev サーバーを即再検出する）。
  func browserActivated()
}

/// 選択コミットの詳細（右ビューアの CommitDetail）。
struct CommitDetailData {
  let commit: Commit
  /// `git diff-tree` のファイル別差分。
  let files: [FileDiff]
}

// MARK: - モデル

/// EditorPane の表示状態（@Observable）。git 実行は持たず、controller が書いた
/// スナップショット＋per-repo UI 状態から表示用データを導出する
/// （導出は EditorPaneModel+Display）。
@Observable final class EditorPaneModel {
  weak var actions: EditorPaneActions?
  var ui = EditorPaneUIState()
  /// 現在言語（`viewerNote` 等モデル側で組む文言用）。EditorPane が実ホルダーを差す。既定は OS 追従
  /// （preview/fixture が注入なしで描ける）。View 側は `@Environment(\.localization)` を使う。
  @ObservationIgnored var localization = LocalizationStore(language: .systemDefault)
  /// 本体パネルの開閉・ツール切替（＝永続対象かつ facade 幅に影響する状態）が変わった通知。
  /// controller が chrome 投影（幅）と保存スケジュールへ配線する。
  @ObservationIgnored var onToolStateChange: () -> Void = {}

  /// 非 nil で空状態（git 外・cwd 不明）。
  var empty: String?
  var branch = ""
  var upstream: String?
  var ahead: Int?
  var behind: Int?
  var files: [FileChange] = []
  var treeNodes: [FileTreeNode] = []
  /// path → unstaged 差分（index ↔ worktree）。
  var unstagedDiffs: [String: FileDiff] = [:]
  /// path → staged 差分（HEAD ↔ index）。
  var stagedDiffs: [String: FileDiff] = [:]
  var commits: [Commit] = []
  var unpushedOids: Set<String> = []
  var historyExhausted = false
  var commitDetail: CommitDetailData?
  var committing = false
  var banner: PaneBanner?

  // MARK: - 埋め込みブラウザ

  /// 検出した dev サーバー URL（＝ブラウザに出す対象）。nil＝未稼働（空状態）。
  var devServerURL: URL?
  /// WKWebView のライブ状態（controller が KVO で書く）。戻/進ボタンの活性に連動。
  var browserCanGoBack = false
  var browserCanGoForward = false
  /// URLバー表示用の現在 URL（WKWebView の現在 URL・未遷移時は devServerURL）。
  var browserDisplayURL: URL?
  /// 埋め込みブラウザ（プロセスに 1 つ・retarget で対象 URL へ遷移し直す）。メインスレッド生成。
  @ObservationIgnored lazy var webView = WKWebView()

  /// worktree ファイルの読み出し（controller が repo を閉じて注入。fixture は辞書引き）。
  @ObservationIgnored var readFile: (String) -> String? = { _ in nil }
  /// 未追跡ファイルの合成 diff（バイナリ・巨大物のガード込み。controller が repo を閉じて注入）。
  @ObservationIgnored var makeUntrackedDiff: (String) -> FileDiff? = { _ in nil }
  /// readFile と未追跡 diff 合成の結果キャッシュ（スナップショット更新で無効化）。
  @ObservationIgnored var contentCache: [String: String?] = [:]
  @ObservationIgnored var untrackedDiffCache: [String: FileDiff] = [:]

  func invalidateContentCache() {
    contentCache = [:]
    untrackedDiffCache = [:]
  }

  // MARK: - 選択・ツール（初期ビュー規則は defaultViewMode 準拠）

  /// FileViewer の文脈。git 変更サブタブのみ .changes、それ以外は .tree。
  var ctx: ViewerCtx { ui.tool == .git && ui.gitTab == .changes ? .changes : .tree }

  /// 文脈×ファイル型ごとの初期ビュー。md は常にプレビュー、他は変更文脈なら diff・ツリーなら全文。
  static func defaultViewMode(ctx: ViewerCtx, path: String?) -> EditorViewMode {
    if let path, isMarkdown(path) { return .preview }
    return ctx == .changes ? .diff : .file
  }

  static func isMarkdown(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return ext == "md" || ext == "markdown"
  }

  func select(path: String?) {
    ui.selectedPath = path
    ui.viewMode = Self.defaultViewMode(ctx: ctx, path: path)
  }

  /// レールボタン押下＝本体パネルのトグル。閉→開でそのツールを表示、開いていて同ツール再押しで閉じ、
  /// 別ツールなら開いたまま切替える。ツリー・git変更へ移るときは初期ビューへ戻す（履歴は選択維持）。
  func selectTool(_ next: EditorTool) {
    if ui.paneOpen, ui.tool == next {
      ui.paneOpen = false
      onToolStateChange()
      return
    }
    ui.paneOpen = true
    ui.tool = next
    if next == .tree { ui.viewMode = Self.defaultViewMode(ctx: .tree, path: ui.selectedPath) }
    if next == .git, ui.gitTab == .changes {
      ui.viewMode = Self.defaultViewMode(ctx: .changes, path: ui.selectedPath)
    }
    if next == .browser { actions?.browserActivated() }
    onToolStateChange()
  }

  /// 現ツールから delta 分ずらして切替（順は tree→git→browser）。
  /// 閉じている（paneOpen==false）ときは現ツールを無視し端から開く: ↓(delta>0)=先頭 tree・↑(delta<0)=末尾 browser。
  /// 開いていて端でさらにその方向へ進むなら、ラップせず本体を閉じる（Cmd+/ 閉と同一副作用: 幅投影＋保存＋フォーカス返し）。
  func selectAdjacentTool(_ delta: Int) {
    let all = EditorTool.allCases
    guard ui.paneOpen else {
      if let edge = delta > 0 ? all.first : all.last { selectTool(edge) }
      return
    }
    guard let i = all.firstIndex(of: ui.tool) else { return }
    let next = i + delta
    guard all.indices.contains(next) else {
      // 端でさらに進む → ラップせず本体を閉じ、フォーカスをターミナルへ返す（Cmd+/ 閉と同一副作用）。
      ui.paneOpen = false
      onToolStateChange()
      actions?.focusTerminal()
      return
    }
    selectTool(all[next])
  }

  /// git サブタブ切替。変更へ移るときは初期ビューへ戻す。
  func selectGitTab(_ next: GitTab) {
    ui.gitTab = next
    if next == .changes {
      ui.viewMode = Self.defaultViewMode(ctx: .changes, path: ui.selectedPath)
    }
  }

  static func dirName(of path: String) -> String {
    guard let i = path.lastIndex(of: "/") else { return "./" }
    return String(path[..<i]) + "/"
  }

  static func fileName(of path: String) -> String {
    (path as NSString).lastPathComponent
  }
}

// MARK: - 相対日時（履歴レール・CommitDetail）

enum RelativeDate {
  static func string(from date: Date, now: Date = Date(), _ l10n: LocalizationStore) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return l10n.string(.relativeJustNow) }
    let minutes = Int(seconds / 60)
    if minutes < 60 {
      return l10n.plural(minutes, one: .relativeMinutesAgoOne, other: .relativeMinutesAgoOther)
    }
    let hours = Int(seconds / 3600)
    if hours < 24 {
      return l10n.plural(hours, one: .relativeHoursAgoOne, other: .relativeHoursAgoOther)
    }
    let days = Int(seconds / 86400)
    if days == 1 { return l10n.string(.relativeYesterday) }
    if days < 30 {
      return l10n.plural(days, one: .relativeDaysAgoOne, other: .relativeDaysAgoOther)
    }
    if days < 365 {
      return l10n.plural(days / 30, one: .relativeMonthsAgoOne, other: .relativeMonthsAgoOther)
    }
    return l10n.plural(days / 365, one: .relativeYearsAgoOne, other: .relativeYearsAgoOther)
  }
}
