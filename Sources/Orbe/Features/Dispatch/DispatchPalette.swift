import SwiftUI

/// Enter で開く行き先。ディレクトリを解決して（既存 worktree 再利用／新規作成）起動する。解決に要る
/// 情報（既存 worktree パス等）を純粋ビルダが焼き込み、実行側（`prepareDirectory`）は分岐するだけにする。
enum DispatchDestination: Equatable {
  case worktree(path: String)
  case localBranch(name: String)
  /// name は `origin/x`（`refs/remotes/` を除いた正確な名前）。
  case remoteBranch(name: String, existingWorktree: String?)
  /// existingBranch は `issue/<n>` ブランチだけ（worktree 無しで）既存か（他 case は git ref に紐づくため不要）。
  case issue(number: Int, existingWorktree: String?, existingBranch: Bool)
}

/// 決定（↵／行タップ）の対象。外（`onExecute`）へ届くのは行き先だけで、ディレクトリを解決しない行為
/// （ブラウザ・clean 画面）はパレットの中で畳む。
enum DispatchAction: Equatable {
  case open(DispatchDestination)
  /// PR 行。`open` は自分の worktree・ブランチ・origin から作れるときの行き先で、`nil` はブラウザで開く。
  case pullRequest(number: Int, open: DispatchDestination?)
  /// Worktrees セクション末尾の `clean` 行。決定でパレット内の clean 画面へ入る。
  case clean

  /// 同じ行か。PR 行は番号で比べる——行き先は fetch の着地や worktree の作成で変わるので、行為の等しさで
  /// 比べると、データの到着で選択が外れる。
  func sameRow(as other: DispatchAction) -> Bool {
    if case .pullRequest(let number, _) = self, case .pullRequest(let otherNumber, _) = other {
      return number == otherNumber
    }
    return self == other
  }
}

/// Dispatch パレットの中身。器（カード枠・焦点契約・高さ契約）は共通で、中身だけ切り替わる。
enum DispatchMode: Equatable {
  case list, clean
  /// 遅れた Local branch を最新化してから作るかを選ぶ画面。
  case refresh
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

/// Enter の動きを先に言う行末ノート（issue/PR 行）。worktree を解決するか、ブラウザで開くか。
enum DispatchEnterNote: Equatable {
  case worktree(DispatchWorktreeKind)
  case browser

  var noteKey: L10nKey {
    switch self {
    case .worktree(let kind): return kind.noteKey
    case .browser: return .dispatchNoteBrowser
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

/// ⌘⇧X で開く Dispatch パレットの表示状態（@Observable）。実データ（worktree/branch/issue/PR）を
/// セクションに持ち、フィルタ・⇥ 起動先切替・決定（↵／行タップ）/⌘↵ 開くの意図をクロージャで外へ配線する。
/// 実データ取得と section 組み立ては `DispatchDataProvider`＋`DispatchSectionBuilder`（外）が担う。
@Observable final class DispatchPaletteModel {
  /// 実データセクション（provider が rebuild で差し替える）。
  var sections: [DispatchSection] = [] {
    didSet { refreshVisible() }
  }
  /// 表示中の画面。器は共通で中身だけ切り替わる。
  private(set) var mode: DispatchMode = .list
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
  let clean = DispatchCleanModel()
  /// 最新化画面の状態。入るたびにブランチの事実（遅れと相対日時）から作り直し、出るときに捨てる。
  private(set) var refresh: DispatchRefreshModel?
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
  /// focus トリガ。`focus()` だけが進め、SwiftUI が監視して `@FocusState` を立てる。
  private(set) var focusToken = 0

  /// ヘッダ ❯ の絞り込み入力（全セクション横断で行を絞る SSOT）。
  var query = "" {
    didSet { refreshVisible() }
  }
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
  /// プライマリ実行（↵／行タップ）。行き先を解決して agent を起動する。呼ぶのは `activate(at:)` だけ。
  var onExecute: (DispatchDestination) -> Void = { _ in }
  /// ⌘↵/「開く」（セカンダリ）。issue/PR／PR に紐づく worktree・branch をブラウザで開く。
  var onOpenWeb: (DispatchItem) -> Void = { _ in }
  /// clean の削除を撃つ（⌘⏎ と失敗分の再試行が共に通る）。中断の札も一緒に渡す。
  var onCleanExecute: ([CleanDeleteRequest], CleanRunToken) -> Void = { _, _ in }
  /// clean の失敗行をタブで開く。パスは解決済み（既存 worktree）なので `prepareDirectory` を通らない。
  var onOpenWorktree: (String) -> Void = { _ in }
  /// 最新化画面の決定。選んだ作り方で worktree を作って起動する（最新化して／そのまま）。
  var onSettleStale: (DispatchStaleChoice, DispatchBranchSync) -> Void = { _, _ in }

  init() {}

  /// 入力を受け付けない状態（worktree 作成中／clean の削除実行中／最新化中）。
  var isBusy: Bool { isPreparing || clean.phase == .deleting || refresh?.isBusy == true }

  /// 最新化画面へ入る。Enter の解決経路が「ff できる遅れ」を返したときだけ来る（判定は provider）。
  /// 画面はブランチの事実（遅れと相対日時）だけから組む——どの行から入ったかに依らない。
  func enterRefresh(sync: DispatchBranchSync, relativeDate: String) {
    refresh = DispatchRefreshModel(sync: sync, relativeDate: relativeDate)
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
  private(set) var visibleSections: [DispatchSection] = []

  /// 可視行を平坦化（選択・フッター連動・スクロールの単位）。
  private(set) var items: [DispatchItem] = []

  private func refreshVisible() {
    visibleSections =
      query.isEmpty
      ? sections
      : sections.compactMap { section in
        // 取得中の印（ローディング行）は落とさない——ヒット 0 件が「無い」のか「まだ届いていない」のかを
        // 見分けられるように、見出しごと残す。
        let items = section.items.filter { $0.isLoadingRow || matches($0) }
        return items.isEmpty ? nil : DispatchSection(title: section.title, items: items)
      }
    items = visibleSections.flatMap(\.items)
  }

  /// フッター連動の元（選択中の item）。
  var selectedItem: DispatchItem? {
    items.indices.contains(selected) ? items[selected] : nil
  }

  /// ↵ による決定。選択行を対象に唯一の決定 funnel（`activate(at:)`）へ入る。
  func activate() { activate(at: selected) }

  /// 決定の唯一の funnel（↵ と行タップが共に通る）。作成中・範囲外・非対話行では実行しない。
  /// 選択を対象行へ確定してから、同じ行の行為をそのまま実行する（選択更新と実行の対象がずれない）。
  /// 外（`onExecute`）へ渡すのは行き先だけ。`clean` 行はパレット内の画面遷移、作れない PR 行は ⌘↵ と
  /// 同じブラウザ（パレットは閉じない）で、どちらもディレクトリを解決しない。
  func activate(at index: Int) {
    guard !isPreparing else { return }
    let its = items
    guard its.indices.contains(index), its[index].isInteractive else { return }
    selected = index
    switch its[index].action {
    case .clean: enterClean()
    case .pullRequest(_, nil): onOpenWeb(its[index])
    case .open(let destination), .pullRequest(_, let destination?): onExecute(destination)
    case nil: break
    }
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

  /// sections 差し替え後の選択復元。差し替え前に選択していた行を「同じ行か」（`sameRow(as:)`）で探し直し、
  /// 見つかれば index を合わせる（裏の gh 更新で行数が変わっても選択が別の行を指さない）。
  /// 見つからない・元が非対話行なら従来どおり clamp する。
  /// 裏の更新はユーザの意図ではないのでモダリティを奪わない（→ `ModalSelection.restore`）。
  func restoreSelection(matching action: DispatchAction?) {
    if let action,
      let index = items.firstIndex(where: { $0.action?.sameRow(as: action) == true })
    {
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
    let fields = [item.name, item.idText, item.detail].compactMap { $0 } + item.aliases
    return fields.contains { $0.localizedCaseInsensitiveContains(query) }
  }
}
