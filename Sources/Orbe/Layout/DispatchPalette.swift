import SwiftUI

/// 決定（↵／行タップ）の対象。行種別ごとに対象ディレクトリの解決方法（既存 worktree 再利用／新規作成）が変わる。
/// 解決に要る情報（既存 worktree パス・fork 判定等）を純粋ビルダが焼き込み、実行側は分岐するだけにする。
enum DispatchAction: Equatable {
  case worktree(path: String)
  case localBranch(name: String, existingWorktree: String?)
  /// name は `origin/x`（remote 短縮名）。
  case remoteBranch(name: String, existingWorktree: String?)
  /// existingBranch は `issue/<n>` ブランチだけ（worktree 無しで）既存か（他 case は git ref に紐づくため不要）。
  case issue(number: Int, existingWorktree: String?, existingBranch: Bool)
  case pullRequest(number: Int, headRef: String, isCrossRepo: Bool, existingWorktree: String?)
}

/// ⇥ 巡回で選ぶ起動先。解決した worktree で agent を走らせるか、素の shell を開くか。
enum DispatchTarget: Equatable {
  case agent(AgentCLI)
  case shell
}

/// worktree 解決の種別。trailingNote／footer 前置句を言語別に引くための意味キー（Japanese 直書きを排し
/// 語順が英語で破綻しないようにする）。既存 worktree 再利用／既存ブランチから checkout／新規作成。
enum DispatchWorktreeKind: Equatable {
  case existing, checkout, new

  /// 行末 muted ノートの文言キー。
  var noteKey: L10nKey {
    switch self {
    case .existing: return .dispatchWorktreeExisting
    case .checkout: return .dispatchWorktreeCheckout
    case .new: return .dispatchWorktreeNew
    }
  }

  /// フッター実行説明の前置句キー（対象名の後・agent 名の前）。
  var prepositionKey: L10nKey {
    switch self {
    case .existing: return .dispatchPrepExisting
    case .checkout: return .dispatchPrepCheckout
    case .new: return .dispatchPrepNew
    }
  }
}

/// PR のレビュー状態（名前直後の muted note を言語別に引く）。
enum DispatchReviewNote: Equatable {
  case reviewRequired, changesRequested, approved

  var key: L10nKey {
    switch self {
    case .reviewRequired: return .dispatchReviewRequired
    case .changesRequested: return .dispatchChangesRequested
    case .approved: return .dispatchApproved
    }
  }
}

/// 情報行の種別（選択・実行の対象外）。ローディング／gh 誘導。文言は View が言語別に引く。
enum DispatchInfoKind: Equatable {
  case loading, ghMissing, ghUnauthed

  var key: L10nKey {
    switch self {
    case .loading: return .commonLoading
    case .ghMissing: return .dispatchGhMissing
    case .ghUnauthed: return .dispatchGhUnauthed
    }
  }
}

/// Dispatch パレット（⌘⇧X）が表示する 1 行。実データ（worktree/branch/issue/PR）と実行ペイロードを持つ。
/// 色や強調は種別＋`isPrimary` から View が導く。
struct DispatchItem: Identifiable {
  /// 先頭グリフ列の種別（見た目とグリフ色を決める）。
  enum Glyph { case worktree, localBranch, remoteBranch, issue, pullRequest }

  let id = UUID()
  /// 先頭グリフ（情報/ローディング行は nil で空欄）。
  var glyph: Glyph?
  /// 色付き ID（issue/PR の `#151` 等・diffAdd）。nil で出さない。
  var idText: String?
  let name: String
  /// 名前の後に muted で出す補足（worktree の `~/wt/… · branch`・branch の `1d前` 等）。nil で出さない。
  var detail: String?
  /// PR のレビュー状態ノート（名前直後・muted・小）。nil で出さない。View が言語別に引く。
  var reviewNote: DispatchReviewNote?
  /// 行末チップ（`#142` 等・branch グリフ付き）。
  var badges: [DispatchBadge] = []
  /// worktree/branch 行が紐づく open PR 番号（issue/PR 行では nil）。
  /// 行末バッジ `#<PR>` と同一の番号（同じ prByHead ルックアップ）を焼く SSOT で、
  /// 「バッジが出る行 ＝ 開ける行」を構造で保証する。
  var linkedPRNumber: Int?
  /// worktree の working リング（10×10）を右端に出すか。
  var showsWorkingIndicator = false
  /// 右端へ寄せる worktree 解決ノート（issue の新規・PR の checkout 等）。nil で出さない。View が言語別に引く。
  var worktreeNote: DispatchWorktreeKind?
  /// 情報/ローディング行の種別（文言は View が引く。対話行は nil）。
  var infoKind: DispatchInfoKind?
  /// アクティブ worktree（グリフ=working 色・名前=chromeText）。他行は muted/secondary。
  var isPrimary = false
  /// 決定（↵／行タップ）のペイロード（情報/ローディング行は nil）。
  var action: DispatchAction?
  /// フッターに出す実行説明（選択に連動して差し替わる）。情報/ローディング行は nil。
  var footer: DispatchFooter?
  /// 選択・実行の対象外の行（gh 誘導情報・ローディング）。キー移動で飛ばし muted 表示する。
  var isInteractive = true
  /// ローディング中の行（先頭に working スピナを出す）。
  var isLoadingRow = false

  /// ⌘↵/「開く」で GitHub をブラウザ表示できる行か（issue/PR／open PR に紐づく worktree・branch）。
  var canOpenWeb: Bool {
    if linkedPRNumber != nil { return true }
    switch action {
    case .issue, .pullRequest: return true
    default: return false
    }
  }
}

/// 行末チップ（`#142` 等）。先頭に branch グリフ・地は tint(diffAdd, .12)。
struct DispatchBadge: Identifiable {
  let text: String
  var id: String { text }
}

/// フッターの実行説明。`target <前置> <agent> を新しいタブで起動` の骨。前置句は worktree 解決種別から、
/// agent 名は選択中 agent（動的）を、後置句は共通キーを View が言語別に挿す（Japanese 断片の連結を排す）。
struct DispatchFooter: Equatable {
  /// 対象名（chromeText）。
  let target: String
  /// worktree 解決種別（前置句キーの由来）。
  let kind: DispatchWorktreeKind
}

/// 見出し（選択対象外）と行の束。
struct DispatchSection: Identifiable {
  let title: String
  var items: [DispatchItem]
  var id: String { title }
}

/// ⌘⇧X で開く Dispatch パレットの表示状態（@Observable）。実データ（worktree/branch/issue/PR）を
/// セクションに持ち、フィルタ・⇥ 起動先切替・決定（↵／行タップ）/⌘↵ 開くの意図をクロージャで外へ配線する。
/// 実データ取得と section 組み立ては `DispatchDataProvider`＋`DispatchSectionBuilder`（外）が担う。
@Observable final class DispatchPaletteModel {
  /// 実データセクション（provider が rebuild で差し替える）。
  var sections: [DispatchSection] = []
  /// 初回ロード完了フラグ。provider の初回 rebuild で立つ。false の間はスケルトン行を出す。
  var hasLoadedOnce = false
  /// 選択とホバー追従ガード（汎用パレットと共有する `ModalSelection`）。
  private var selection = ModalSelection()

  /// 可視行（visibleSections を平坦化）を数えた選択 index。
  /// ホバー追従以外の代入はモダリティを `.keyboard` へ戻す（→ `ModalSelection`）。
  var selected: Int {
    get { selection.index }
    set { selection.index = newValue }
  }

  /// 実マウス移動（`MouseMovedDetector`）が `.pointer` へ落とす。
  var inputModality: InputModality {
    get { selection.modality }
    set { selection.modality = newValue }
  }

  /// ホバー開始による選択追従。実マウス移動後（`.pointer`）だけ効き、決定（`onExecute`）は呼ばない。
  /// 関門は決定（`activate(at:)`）と同じ——作成中・範囲外・非対話行では選択を動かさない。
  func hoverSelect(_ index: Int) {
    guard !isPreparing else { return }
    let its = items
    guard its.indices.contains(index), its[index].isInteractive else { return }
    selection.hoverSelect(index)
  }
  /// focus トリガ。提示元がインクリメントし、SwiftUI が監視して `@FocusState` を立てる。
  var focusToken = 0

  /// ヘッダ ❯ の絞り込み入力（全セクション横断で行を絞る SSOT）。
  var query = ""
  /// ⇥ で巡回する起動先（agent もしくは shell）。default agent 直後に shell をスプライスして持つ。
  var targets: [DispatchTarget] = []
  /// ⇥ で巡回する選択起動先の index。初期は default agent の index。
  var selectedTargetIndex = 0
  /// Issues/PR セクションのフォールバック分岐（情報行/非表示の判断は builder が消費する）。
  var githubState: GitHubAvailability = .ready
  /// 実行失敗の一時表示（palette は閉じない）。
  var errorMessage: String?
  /// prepareDirectory 実行中の進捗表示フラグ（worktree 作成待ち・palette は閉じない）。
  /// true の間はフッターにスピナ＋「作成中…」を出し、入力（Enter 再実行・選択移動・検索）を受け付けない。
  var isPreparing = false

  var onDismiss: () -> Void = {}
  /// プライマリ実行（↵／行タップ）。行の action を解決して agent を起動する。呼ぶのは `activate(at:)` だけ。
  var onExecute: (DispatchItem) -> Void = { _ in }
  /// ⌘↵/「開く」（セカンダリ）。issue/PR／PR に紐づく worktree・branch をブラウザで開く。
  var onOpenWeb: (DispatchItem) -> Void = { _ in }

  init() {}

  /// キー操作を受けるため focusToken を進めて first responder を確定させる。
  func focus() { focusToken &+= 1 }

  /// query で絞った可視セクション（空になったセクションは落とす）。
  var visibleSections: [DispatchSection] {
    guard !query.isEmpty else { return sections }
    return sections.compactMap { section in
      let items = section.items.filter { matches($0) }
      return items.isEmpty ? nil : DispatchSection(title: section.title, items: items)
    }
  }

  /// 可視行を平坦化（選択・フッター連動・スクロールの単位）。
  var items: [DispatchItem] { visibleSections.flatMap(\.items) }

  /// フッター連動の元（選択中の item）。
  var selectedItem: DispatchItem? {
    items.indices.contains(selected) ? items[selected] : nil
  }

  /// ↵ による決定。選択行を対象に唯一の決定 funnel（`activate(at:)`）へ入る。
  func activate() { activate(at: selected) }

  /// 決定の唯一の funnel（↵ と行タップが共に通る）。作成中・範囲外・非対話行では実行しない。
  /// 選択を対象行へ確定してから、同じ行の item をそのまま実行へ渡す（選択更新と実行の対象がずれない）。
  func activate(at index: Int) {
    guard !isPreparing else { return }
    let its = items
    guard its.indices.contains(index), its[index].isInteractive else { return }
    selected = index
    onExecute(its[index])
  }

  /// 対話行のみを巡回する選択移動（情報/ローディング行は飛ばす・端で wrap）。
  func move(_ direction: Int) {
    let its = items
    guard its.contains(where: \.isInteractive) else { return }
    var i = selected
    repeat { i = (i + direction + its.count) % its.count } while !its[i].isInteractive
    selected = i
  }

  /// 対話行の先頭/末尾へジャンプ（d<0=先頭・d>=0=末尾。非対話行は除外・空は no-op）。
  func jump(_ d: Int) {
    let its = items
    let i = d < 0 ? its.firstIndex(where: \.isInteractive) : its.lastIndex(where: \.isInteractive)
    guard let i else { return }
    selected = i
  }

  /// query 変化後・sections 差し替え後に選択を可視の対話行へ収める。
  func clampSelection() {
    let its = items
    guard !its.isEmpty else {
      selected = 0
      return
    }
    if selected >= its.count { selected = its.count - 1 }
    if !its[selected].isInteractive {
      selected = its.firstIndex(where: \.isInteractive) ?? 0
    }
  }

  /// sections 差し替え後の選択復元。差し替え前に選択していた行を `DispatchAction` の同一性で探し直し、
  /// 見つかれば index を合わせる（裏の gh 更新で行数が変わっても選択が別の行を指さない）。
  /// 見つからない・元が非対話行なら従来どおり clamp する。
  /// 裏の更新はユーザの意図ではないのでモダリティを奪わない（→ `ModalSelection.restore`）。
  func restoreSelection(matching action: DispatchAction?) {
    if let action, let index = items.firstIndex(where: { $0.action == action }) {
      selection.restore(index)
      return
    }
    clampSelection()
  }

  /// 入力欄から query が変わった。選択を先頭の可視対話行へ戻す。
  func onQueryChanged() {
    selected = 0
    clampSelection()
  }

  /// 検出済み agent から巡回対象を組む。default agent の直後に shell をスプライスし、初期選択は
  /// default agent（0 agent 時は index0＝shell）。スプライス/初期選択のロジックをここへ閉じる。
  func setTargets(agents: [AgentCLI], defaultCommand: String?) {
    var t = agents.map { DispatchTarget.agent($0) }
    let defaultIndex = agents.firstIndex { $0.command == defaultCommand } ?? 0
    t.insert(.shell, at: min(defaultIndex + 1, t.count))
    targets = t
    selectedTargetIndex = defaultIndex
  }

  /// ⇥ で選択起動先を巡回する。
  func cycleTarget() {
    guard !targets.isEmpty else { return }
    selectedTargetIndex = (selectedTargetIndex + 1) % targets.count
  }

  /// 選択中の起動先（targets が空なら nil）。
  var selectedTarget: DispatchTarget? {
    targets.indices.contains(selectedTargetIndex) ? targets[selectedTargetIndex] : nil
  }

  /// ヘッダチップ/フッターに出す起動先名。agent は raw command、shell はリテラル（技術語で日英同一）。
  var selectedTargetName: String {
    switch selectedTarget {
    case .agent(let a): return a.command
    case .shell: return "shell"
    case nil: return ""
    }
  }

  private func matches(_ item: DispatchItem) -> Bool {
    guard item.isInteractive else { return false }
    let fields = [item.name, item.idText, item.detail].compactMap { $0 }
    return fields.contains { $0.localizedCaseInsensitiveContains(query) }
  }
}
