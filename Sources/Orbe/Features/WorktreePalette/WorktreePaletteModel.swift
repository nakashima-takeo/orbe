import SwiftUI

/// ⌘T で開く worktree パレットの表示状態（@Observable）。実データ（worktree/branch）を
/// セクションに持ち、フィルタ・⇥ 起動先切替・⇧⇥ ベース切替・決定（↵／行タップ）の意図をクロージャで
/// 外へ配線する。実データ取得と section 組み立ては `WorktreePaletteDataProvider`＋
/// `WorktreePaletteSectionBuilder`（外）が担う。
@Observable final class WorktreePaletteModel {
  /// 実データセクション（provider が rebuild で差し替える。作成行と一致なしの注記はこの型が足す）。
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
  /// ベースを選ぶ画面の状態。入るたびに候補から作り直し、出るときに捨てる。
  private(set) var basePicker: WorktreeBasePickerModel?
  /// 初回ロード完了フラグ。provider の初回 rebuild で立つ。false の間はスケルトン行を出す。
  var hasLoadedOnce = false
  /// 選択とホバー追従ガード（汎用パレットと共有する `ModalSelection`）。
  private var selection = ModalSelection(0)
  /// 選択が入力の規則（`defaultSelection`）に従っている。入力が変わると立ち、ユーザーが選択を
  /// 動かすと下りる——データの到着や有効性の答えで選択を動かしてよいのは、立っている間だけ。
  private var selectionFollowsInput = true

  /// 可視行（visibleSections を平坦化）を数えた選択 index。
  /// ホバー追従以外の代入はモダリティを `.keyboard` へ戻す（→ `ModalSelection`）。
  var selected: Int {
    get { selection.value }
    set { selection.value = newValue }
  }

  /// 実マウス移動（`MouseMovedDetector`）が `.pointer` へ落とす。
  var inputModality: InputModality {
    get { selection.modality }
    set { selection.modality = newValue }
  }

  /// ホバー開始による選択追従。実マウス移動後（`.pointer`）だけ効き、決定（`onExecute`）は呼ばない。
  /// 関門は決定（`activate(at:)`）と同じ——入力ロック中・範囲外では選択を動かさない。
  func hoverSelect(_ index: Int) {
    guard !isLocked, items.indices.contains(index), inputModality == .pointer else { return }
    selectionFollowsInput = false
    selection.hoverSelect(index)
  }
  /// focus トリガ。`focus()` だけが進め、SwiftUI が監視して `@FocusState` を立てる。
  private(set) var focusToken = 0

  /// ヘッダ ❯ の入力（全セクション横断で行を絞る SSOT・新しいブランチ名）。
  var query = "" {
    didSet { refreshVisible() }
  }
  /// ⇥ で巡回する起動先。既定の agent、shell、残りの検出 agent の順。
  private(set) var targets: [WorktreePaletteTarget] = []
  /// ⇥ で巡回する選択起動先の index。初期は既定の agent（agent が無ければ shell）。
  private(set) var selectedTargetIndex = 0
  /// 実行失敗の一時表示（palette は閉じない）。
  var errorMessage: String?
  /// 決定の後、行き先が決まるまでの待ち（`prepareDirectory` の実行中）の進捗表示フラグ（palette は閉じない）。
  /// true の間はフッターにスピナ＋「作成中…」を出し、入力（Enter 再実行・選択移動・検索）を受け付けない。
  var isPreparing = false
  /// 行がまだ決まらない間に押された ↵ を預かっている（→ `activate()`）。
  private(set) var hasPendingActivation = false

  /// 作成行の名前と作成先の衝突の規則（provider が差し替える）。nil は作成行を出さない（非 git・未ロード）。
  var newBranchRules: WorktreeNewBranchRules? {
    didSet { refreshVisible() }
  }
  /// 打った名前がブランチ名として有効かの、最後に届いた git の答え。今の入力への答えかは `name` で見る。
  var branchNameAnswer: (name: String, isValid: Bool)? {
    didSet { refreshVisible() }
  }
  /// ベースの選択肢の材料（provider が rebuild で差し替える）。
  var baseFacts: WorktreeBaseFacts? {
    didSet { reconcileBase() }
  }
  /// ベースを選ぶ画面の候補（ローカルの後にリモート、それぞれ新しい順）。
  var baseCandidates: [WorktreeBaseCandidate] = []
  /// ベースを選ぶ画面で選んだ名前（選んだ後だけ列に出る）。
  var pickedBase: String? {
    didSet { reconcileBase() }
  }
  /// 選んだ選択肢の役割。nil は「まだ選んでいない」で、初期規則（前回、無ければ既定）が当たる。
  var selectedBaseRole: WorktreeBaseRole?
  /// ベースのバーの選択肢（事実と選んだ名前から純関数で組んだ値）。
  private(set) var baseChoices: [WorktreeBaseChoice] = WorktreeBaseChoices.build(
    facts: nil, picked: nil)

  var onDismiss: () -> Void = {}
  /// プライマリ実行（↵／行タップ）。行き先を解決して agent を起動する。呼ぶのは `activate(at:)` だけ。
  var onExecute: (WorktreePaletteDestination) -> Void = { _ in }
  /// 入力が変わった。その名前がブランチ名として有効かを問う（答えは `applyBranchNameCheck`）。
  var onCheckBranchName: (String) -> Void = { _ in }
  /// clean の削除を撃つ（⌘⏎ と失敗分の再試行が共に通る）。中断の札も一緒に渡す。
  var onCleanExecute: ([CleanDeleteRequest], CleanRunToken) -> Void = { _, _ in }
  /// clean の失敗行をタブで開く。パスは解決済み（既存 worktree）なので `prepareDirectory` を通らない。
  var onOpenWorktree: (String) -> Void = { _ in }
  /// 最新化画面の決定。選んだ作り方で worktree を作って起動する（最新化して／そのまま）。
  var onSettleStale: (WorktreePaletteStaleChoice, WorktreePaletteBranchSync) -> Void = { _, _ in }

  init() {}

  /// 入力を受け付けない状態（worktree 作成中／預かった ↵ の待ち）。
  var isLocked: Bool { isPreparing || hasPendingActivation }

  /// scrim で閉じさせない状態（入力ロック中／clean の削除実行中／最新化中）。
  var isBusy: Bool { isLocked || clean.phase == .deleting || refresh?.isBusy == true }

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

  /// ベースを選ぶ画面へ入る。焦点の宛先は一覧と同じ入力欄のまま（中身だけが替わる）。
  func enterBasePicker() {
    basePicker = WorktreeBasePickerModel(candidates: baseCandidates)
    mode = .basePicker
    focus()
  }

  /// ベースを選ぶ画面の esc。選ばずに戻る（ベースの選択は「ほか…」のまま）。
  func exitBasePicker() {
    basePicker = nil
    mode = .list
    focus()
  }

  /// ベースを選ぶ画面の ↵。カーソルのブランチをベースに決めて一覧へ戻る。
  func confirmBasePick() {
    guard let name = basePicker?.selectedItem?.name else { return }
    pickBase(name)
    exitBasePicker()
  }

  /// キー操作を受けるため focusToken を進めて first responder を確定させる。
  func focus() { focusToken &+= 1 }

  /// 可視セクション（絞り込みで空になった欄は落とし、作成行と一致なしの注記を足す）。
  /// `sections` / `query` / 有効性の答え の変化時に 1 回だけ計算して保持する——1 回の打鍵で何度も
  /// 読まれるので、読むたびに全行を照合し直すと件数が千を超えたとき打鍵がもたつく。
  private(set) var visibleSections: [WorktreePaletteSection] = []

  /// 可視行を平坦化（選択・フッター連動・スクロールの単位）。
  private(set) var items: [WorktreePaletteItem] = []

  private func refreshVisible() {
    let existing =
      query.isEmpty
      ? sections
      : sections.compactMap { section in
        let items = section.items.filter(matches)
        return items.isEmpty ? nil : section.with(items: items)
      }
    var visible: [WorktreePaletteSection] = []
    if let name = creatableName {
      visible.append(
        WorktreePaletteSection(
          title: .newBranch, items: [WorktreePaletteSectionBuilder.newBranchItem(name: name)]))
    }
    visible += existing
    if !query.isEmpty, hasLoadedOnce, existing.isEmpty {
      visible.append(
        WorktreePaletteSection(
          title: .worktreesAndBranches, items: [], emptyNote: .worktreePaletteNoMatch))
    }
    visibleSections = visible
    items = visible.flatMap(\.items)
  }

  /// フッター連動の元（選択中の item）。
  var selectedItem: WorktreePaletteItem? {
    items.indices.contains(selected) ? items[selected] : nil
  }

  /// ↵ による決定。行がまだ決まらない間（`isSettled` が偽）は ↵ を預かり、決まった時点の選択で
  /// 実行する（`settlePendingActivation`）——開いた直後や名前を打った直後の ↵ を空振りさせない。
  func activate() {
    guard mode == .list, !isLocked else { return }
    guard isSettled else {
      hasPendingActivation = true
      return
    }
    activate(at: selected)
  }

  /// 決定の唯一の funnel（↵ と行タップが共に通る）。入力ロック中・範囲外では実行しない。
  /// 選択を対象行へ確定してから、同じ行の行為をそのまま実行する（選択更新と実行の対象がずれない）。
  /// 外（`onExecute`）へ渡すのは行き先だけ。`clean` 行と「ほか…」の作成行はパレット内の画面遷移で、
  /// ディレクトリを解決しない。
  func activate(at index: Int) {
    guard !isLocked, items.indices.contains(index) else { return }
    selectionFollowsInput = false
    selected = index
    switch items[index].action {
    case .clean:
      enterClean()
    case .open(let destination):
      onExecute(destination)
    case .createBranch(let name):
      // 答え待ち（直前の答えで出ている行）は作らない。↵ は `activate()` が預かるので、来るのはタップだけ。
      guard !isAwaitingBranchNameAnswer, let choice = selectedBaseChoice else { return }
      guard let base = choice.base else { return enterBasePicker() }
      onExecute(.newBranch(name: name, base: base))
    }
  }

  /// 行が決まっているか。決まっていないのは、初回の一覧が届く前と、今の入力への有効性の答えが無いまま
  /// 作成行（または行が 1 つも無い状態）を選んでいるとき。
  var isSettled: Bool {
    guard hasLoadedOnce else { return false }
    guard isAwaitingBranchNameAnswer else { return true }
    switch selectedItem?.action {
    case .createBranch, nil: return false
    case .open, .clean: return true
    }
  }

  /// 預かった ↵ を、行が決まっていれば今の選択で実行する。データの到着と有効性の答えの後に呼ぶ。
  private func settlePendingActivation() {
    guard hasPendingActivation, isSettled else { return }
    hasPendingActivation = false
    guard !items.isEmpty else { return }
    activate(at: selected)
  }

  /// 行を巡回する選択移動（端で wrap）。
  func move(_ direction: Int) {
    guard !items.isEmpty else { return }
    selectionFollowsInput = false
    selected = (selected + direction + items.count) % items.count
  }

  /// 先頭/末尾へジャンプ（d<0=先頭・d>=0=末尾。空は no-op）。
  func jump(_ d: Int) {
    guard !items.isEmpty else { return }
    selectionFollowsInput = false
    selected = d < 0 ? 0 : items.count - 1
  }

  /// sections 差し替え後の選択復元。入力の規則に従っている間はその規則を当て直し、ユーザーが動かした
  /// 後は差し替え前に選択していた行を同じ行為で探し直す（裏の列挙の引き直しで行数が変わっても選択が
  /// 別の行を指さない）。見つからなければ範囲へ収める。最後に預かった ↵ を決着させる。
  /// 裏の更新はユーザの意図ではないのでモダリティを奪わない（→ `ModalSelection.restore`）。
  func restoreSelection(matching action: WorktreePaletteAction?) {
    reselect(previous: action)
    settlePendingActivation()
  }

  private func reselect(previous action: WorktreePaletteAction?) {
    if selectionFollowsInput {
      selection.restore(defaultSelection)
    } else if let action, let index = items.firstIndex(where: { $0.action == action }) {
      selection.restore(index)
    } else {
      selection.restore(min(selected, max(items.count - 1, 0)))
    }
  }

  /// 入力欄から query が変わった。選択を入力の規則へ戻し、新しい名前の有効性を問う。
  func onQueryChanged() {
    selectionFollowsInput = true
    selected = defaultSelection
    guard !query.isEmpty else { return }
    // `-` で始まる名前は git に問わず無効とする（作成で `git worktree add -b` のオプションとして渡る余地を消す）。
    guard !query.hasPrefix("-") else { return applyBranchNameCheck(query, isValid: false) }
    onCheckBranchName(query)
  }

  /// 入力の規則による選択。入力が空なら今の worktree の行。入力があれば一致した既存の行の先頭、
  /// 無ければ作成行。
  private var defaultSelection: Int {
    if query.isEmpty { return items.firstIndex(where: \.isCurrent) ?? 0 }
    return items.firstIndex { item in
      if case .createBranch = item.action { return false }
      return true
    } ?? 0
  }

  /// 打った名前の有効性の答えが届いた。古い問い（今の入力と違う名前）への答えは捨てる。
  func applyBranchNameCheck(_ name: String, isValid: Bool) {
    guard name == query else { return }
    let action = selectedItem?.action
    branchNameAnswer = (name, isValid)
    reselect(previous: action)
    settlePendingActivation()
  }

  /// 作成行に出す名前（出さないなら nil）。答えがまだ無い間は直前の答えで出すかを決め、名前は今の
  /// 入力にする——打鍵のたびに行が消えて出直さない。`-` で始まる名前は答えを待たずに出さない。
  private var creatableName: String? {
    guard !query.isEmpty, !query.hasPrefix("-"), let rules = newBranchRules, rules.allows(query)
    else { return nil }
    return branchNameAnswer?.isValid == true ? query : nil
  }

  /// 検出済み agent から巡回対象を組む。既定の agent を先頭に、shell をその直後に、残りの agent を
  /// 検出順に並べる。既定が検出に無ければ検出順の先頭を既定とする。初期選択は先頭。
  func setTargets(agents: [AgentCLI], defaultCommand: String?) {
    let defaultAgent = agents.first { $0.command == defaultCommand } ?? agents.first
    let rest = agents.filter { $0 != defaultAgent }.map(WorktreePaletteTarget.agent)
    targets = (defaultAgent.map { [.agent($0)] } ?? []) + [.shell] + rest
    selectedTargetIndex = 0
  }

  /// 既定の agent（「既定」の札を付ける起動先）。agent が 1 つも無ければ nil。
  var defaultTarget: WorktreePaletteTarget? {
    guard case .agent = targets.first else { return nil }
    return targets.first
  }

  /// ⇥ で選択起動先を巡回する。
  func cycleTarget() {
    guard !targets.isEmpty else { return }
    selectedTargetIndex = (selectedTargetIndex + 1) % targets.count
  }

  /// 起動先のボタンのクリック。
  func chooseTarget(at index: Int) {
    guard !isLocked, targets.indices.contains(index) else { return }
    selectedTargetIndex = index
  }

  /// 選択中の起動先（targets が空なら nil）。
  var selectedTarget: WorktreePaletteTarget? {
    targets.indices.contains(selectedTargetIndex) ? targets[selectedTargetIndex] : nil
  }

  /// フッターに出す起動先名。
  var selectedTargetName: String { selectedTarget?.name ?? "" }

  /// 事実か選んだ名前が変わった。列を組み直し、選んだ役割が消えたら未選択へ戻す。
  private func reconcileBase() {
    baseChoices = WorktreeBaseChoices.build(facts: baseFacts, picked: pickedBase)
    if let role = selectedBaseRole, !baseChoices.contains(where: { $0.role == role }) {
      selectedBaseRole = nil
    }
  }

  private func matches(_ item: WorktreePaletteItem) -> Bool {
    let fields = [item.name, item.detail].compactMap { $0 } + item.aliases
    return fields.contains { $0.localizedCaseInsensitiveContains(query) }
  }
}
