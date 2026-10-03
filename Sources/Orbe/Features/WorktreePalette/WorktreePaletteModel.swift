import SwiftUI

/// Enter で開く行き先。ディレクトリを解決して（既存 worktree 再利用／新規作成）起動する。解決に要る
/// 情報（既存 worktree パス等）を純粋ビルダが焼き込み、実行側（`prepareDirectory`）は分岐するだけにする。
enum WorktreePaletteDestination: Equatable {
  case worktree(path: String)
  case localBranch(name: String)
  /// name は `origin/x`（`refs/remotes/` を除いた正確な名前）。
  case remoteBranch(name: String, existingWorktree: String?)
  /// base から name の新しいブランチ（upstream なし）を切り、その worktree を作る。
  case newBranch(name: String, base: WorktreeBase)
}

/// 新しいブランチを切るベース。既定ブランチは**参照ではなく意図**として持ち、名前の解決を作成の直前まで
/// 遅らせる——提示時に読んだ名前を捕まえると、着地を待つあいだに fetch が `origin/HEAD` を作っても
/// （git の `followRemoteHEAD` 既定）フォールバックの固定名のまま撃ってしまう。
enum WorktreeBase: Equatable {
  case ref(String)
  case defaultBranch
}

/// 決定（↵／行タップ）の対象。外（`onExecute`）へ届くのは行き先だけで、ディレクトリを解決しない行為
/// （clean 画面）はパレットの中で畳む。
enum WorktreePaletteAction: Equatable {
  case open(WorktreePaletteDestination)
  /// Worktrees セクション末尾の `clean` 行。決定でパレット内の clean 画面へ入る。
  case clean
}

/// worktree パレットの中身。器（カード枠・焦点契約・高さ契約）は共通で、中身だけ切り替わる。
enum WorktreePaletteMode: Equatable {
  case list, clean
  /// 遅れた Local branch を最新化してから作るかを選ぶ画面。
  case refresh
}

/// ⇥ 巡回で選ぶ起動先。解決した worktree で agent を走らせるか、素の shell を開くか。
enum WorktreePaletteTarget: Equatable {
  case agent(AgentCLI)
  case shell
}

/// worktree 解決の種別。trailingNote／footer 前置句を言語別に引くための意味キー（Japanese 直書きを排し
/// 語順が英語で破綻しないようにする）。既存 worktree 再利用／既存ブランチから checkout／新規作成。
enum WorktreeOpenKind: Equatable {
  case existing, checkout, new

  /// 行末 muted ノートの文言キー。
  var noteKey: L10nKey {
    switch self {
    case .existing: return .worktreePaletteWorktreeExisting
    case .checkout: return .worktreePaletteWorktreeCheckout
    case .new: return .worktreePaletteWorktreeNew
    }
  }

  /// フッター実行説明の前置句キー（対象名の後・agent 名の前）。
  var prepositionKey: L10nKey {
    switch self {
    case .existing: return .worktreePalettePrepExisting
    case .checkout: return .worktreePalettePrepCheckout
    case .new: return .worktreePalettePrepNew
    }
  }
}

/// ⌘T で開く worktree パレットの表示状態（@Observable）。実データ（worktree/branch）を
/// セクションに持ち、フィルタ・⇥ 起動先切替・決定（↵／行タップ）の意図をクロージャで外へ配線する。
/// 実データ取得と section 組み立ては `WorktreePaletteDataProvider`＋`WorktreePaletteSectionBuilder`（外）が担う。
@Observable final class WorktreePaletteModel {
  /// 実データセクション（provider が rebuild で差し替える）。
  var sections: [WorktreePaletteSection] = [] {
    didSet { refreshVisible() }
  }
  /// 表示中の画面。器は共通で中身だけ切り替わる。
  private(set) var mode: WorktreePaletteMode = .list
  /// 最新の分類結果（provider が rebuild ごとに更新）。nil は分類レーンが未着地。
  /// **clean を開いている間は、着地がそのまま画面へ届く**（選択可否は行ごとの `isReady` が決める）。
  var classification: [CleanRow]? {
    didSet {
      guard mode == .clean else { return }
      clean.apply(rows: classification ?? [])
    }
  }
  /// 分類の材料がまだ動いているか（provider の導出値。0 行の clean にスケルトンを出す入力）。
  /// 行と違って画面を跨いで意味が変わらないので、mode を問わずそのまま流す＝clean を開く時点で
  /// 既に同値になっている。
  var classificationPending = false {
    didSet { clean.classificationPending = classificationPending }
  }
  /// clean 画面の状態。
  let clean = WorktreeCleanModel()
  /// 最新化画面の状態。入るたびにブランチの事実（遅れと相対日時）から作り直し、出るときに捨てる。
  private(set) var refresh: WorktreePaletteRefreshModel?
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
  /// 関門は決定（`activate(at:)`）と同じ——作成中・範囲外では選択を動かさない。
  func hoverSelect(_ index: Int) {
    guard !isPreparing, items.indices.contains(index) else { return }
    selection.hoverSelect(index)
  }
  /// focus トリガ。`focus()` だけが進め、SwiftUI が監視して `@FocusState` を立てる。
  private(set) var focusToken = 0

  /// ヘッダ ❯ の絞り込み入力（全セクション横断で行を絞る SSOT）。
  var query = "" {
    didSet { refreshVisible() }
  }
  /// ⇥ で巡回する起動先（agent もしくは shell）。default agent 直後に shell をスプライスして持つ。
  var targets: [WorktreePaletteTarget] = []
  /// ⇥ で巡回する選択起動先の index。初期は default agent の index。
  var selectedTargetIndex = 0
  /// 実行失敗の一時表示（palette は閉じない）。
  var errorMessage: String?
  /// 決定の後、行き先が決まるまでの待ち（`prepareDirectory` の実行中）の進捗表示フラグ（palette は閉じない）。
  /// true の間はフッターにスピナ＋「作成中…」を出し、入力（Enter 再実行・選択移動・検索）を受け付けない。
  var isPreparing = false

  var onDismiss: () -> Void = {}
  /// プライマリ実行（↵／行タップ）。行き先を解決して agent を起動する。呼ぶのは `activate(at:)` だけ。
  var onExecute: (WorktreePaletteDestination) -> Void = { _ in }
  /// clean の削除を撃つ（⌘⏎ と失敗分の再試行が共に通る）。中断の札も一緒に渡す。
  var onCleanExecute: ([CleanDeleteRequest], CleanRunToken) -> Void = { _, _ in }
  /// clean の失敗行をタブで開く。パスは解決済み（既存 worktree）なので `prepareDirectory` を通らない。
  var onOpenWorktree: (String) -> Void = { _ in }
  /// 最新化画面の決定。選んだ作り方で worktree を作って起動する（最新化して／そのまま）。
  var onSettleStale: (WorktreePaletteStaleChoice, WorktreePaletteBranchSync) -> Void = { _, _ in }

  init() {}

  /// 入力を受け付けない状態（worktree 作成中／clean の削除実行中／最新化中）。
  var isBusy: Bool { isPreparing || clean.phase == .deleting || refresh?.isBusy == true }

  /// 最新化画面へ入る。Enter の解決経路が「ff できる遅れ」を返したときだけ来る（判定は provider）。
  /// 画面はブランチの事実（遅れと相対日時）だけから組む——どの行から入ったかに依らない。
  func enterRefresh(sync: WorktreePaletteBranchSync, relativeDate: String) {
    refresh = WorktreePaletteRefreshModel(sync: sync, relativeDate: relativeDate)
    mode = .refresh
    focus()
  }

  /// 最新化画面の esc。選択・失敗では list へ戻る（カーソルは入った行のまま）。busy は無反応。
  func exitRefresh() {
    guard let refresh, !refresh.isBusy else { return }
    leaveRefresh()
  }

  /// 作成の失敗を畳む唯一の 1 本（一覧の Enter・そのまま作成・最新化後の作成が共に通る）。
  /// 理由はフッタに赤で出し、最新化画面に居たなら一覧へ戻す——ff は済んでいるので画面に残す事実が無い。
  func failPreparation(_ message: String) {
    isPreparing = false
    errorMessage = message
    if mode == .refresh { leaveRefresh() }
  }

  private func leaveRefresh() {
    refresh = nil
    mode = .list
    focus()
  }

  /// clean 画面へ入る。**分類が未着地でも即座に入る**——開いてから行が生えるほうが、押しても
  /// 何も起きないより正しい（0 行の間はスケルトン行が空フレームを埋める）。
  func enterClean() {
    clean.enter(rows: classification ?? [])
    mode = .clean
    focus()
  }

  /// list へ戻る（パレットは閉じない）。行数が変わっていてもカーソルは `clean` 行を指す。
  func exitClean() {
    guard clean.phase == .selecting else { return }
    mode = .list
    if let index = items.firstIndex(where: { $0.action == .clean }) { selected = index }
    focus()
  }

  /// キー操作を受けるため focusToken を進めて first responder を確定させる。
  func focus() { focusToken &+= 1 }

  /// query で絞った可視セクション（空になったセクションは落とす）。`sections` / `query` の変化時に
  /// 1 回だけ計算して保持する——1 回の打鍵で何度も読まれるので、読むたびに全行を照合し直すと
  /// 件数が千を超えたとき打鍵がもたつく。
  private(set) var visibleSections: [WorktreePaletteSection] = []

  /// 可視行を平坦化（選択・フッター連動・スクロールの単位）。
  private(set) var items: [WorktreePaletteItem] = []

  private func refreshVisible() {
    visibleSections =
      query.isEmpty
      ? sections
      : sections.compactMap { section in
        let items = section.items.filter(matches)
        return items.isEmpty ? nil : WorktreePaletteSection(title: section.title, items: items)
      }
    items = visibleSections.flatMap(\.items)
  }

  /// フッター連動の元（選択中の item）。
  var selectedItem: WorktreePaletteItem? {
    items.indices.contains(selected) ? items[selected] : nil
  }

  /// ↵ による決定。選択行を対象に唯一の決定 funnel（`activate(at:)`）へ入る。
  func activate() { activate(at: selected) }

  /// 決定の唯一の funnel（↵ と行タップが共に通る）。作成中・範囲外では実行しない。
  /// 選択を対象行へ確定してから、同じ行の行為をそのまま実行する（選択更新と実行の対象がずれない）。
  /// 外（`onExecute`）へ渡すのは行き先だけ。`clean` 行はパレット内の画面遷移で、ディレクトリを解決しない。
  func activate(at index: Int) {
    guard !isPreparing, items.indices.contains(index) else { return }
    selected = index
    switch items[index].action {
    case .clean: enterClean()
    case .open(let destination): onExecute(destination)
    }
  }

  /// 行を巡回する選択移動（端で wrap）。
  func move(_ direction: Int) {
    guard !items.isEmpty else { return }
    selected = (selected + direction + items.count) % items.count
  }

  /// 先頭/末尾へジャンプ（d<0=先頭・d>=0=末尾。空は no-op）。
  func jump(_ d: Int) {
    guard !items.isEmpty else { return }
    selected = d < 0 ? 0 : items.count - 1
  }

  /// query 変化後・sections 差し替え後に選択を可視の行へ収める。
  func clampSelection() {
    selected = min(selected, max(items.count - 1, 0))
  }

  /// sections 差し替え後の選択復元。差し替え前に選択していた行を同じ行為で探し直し、
  /// 見つかれば index を合わせる（裏の gh 更新で行数が変わっても選択が別の行を指さない）。
  /// 見つからなければ clamp する。
  /// 裏の更新はユーザの意図ではないのでモダリティを奪わない（→ `ModalSelection.restore`）。
  func restoreSelection(matching action: WorktreePaletteAction?) {
    if let action,
      let index = items.firstIndex(where: { $0.action == action })
    {
      selection.restore(index)
      return
    }
    clampSelection()
  }

  /// 入力欄から query が変わった。選択を先頭の可視行へ戻す。
  func onQueryChanged() {
    selected = 0
  }

  /// 検出済み agent から巡回対象を組む。default agent の直後に shell をスプライスし、初期選択は
  /// default agent（0 agent 時は index0＝shell）。スプライス/初期選択のロジックをここへ閉じる。
  func setTargets(agents: [AgentCLI], defaultCommand: String?) {
    var t = agents.map { WorktreePaletteTarget.agent($0) }
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
  var selectedTarget: WorktreePaletteTarget? {
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

  private func matches(_ item: WorktreePaletteItem) -> Bool {
    let fields = [item.name, item.detail].compactMap { $0 } + item.aliases
    return fields.contains { $0.localizedCaseInsensitiveContains(query) }
  }
}
