import Foundation
import Observation

/// タスクの表の一覧 1 つの状態（入力・選択）と、表に載せたタスクの並び。並びはリストの更新（入力・絞り込み・
/// 並びの変化）のときだけ空にして組み直し、その間は行を同じ並びのまま残す——行が人の知らない瞬間に消えたり
/// 動いたりすると、次のクリックや space が別のタスクに当たるため。入力の変化はこの一覧の更新なので、ここで空にする。
struct TaskPaletteTaskList {
  var state = ListState<TaskPaletteRowID>() {
    didSet { if state.query != oldValue.query { listed = [] } }
  }
  /// 表に載せたタスクの ID（表の並びの順）。リストの更新で空にし、中身を書くのは `TaskPaletteRows.listing` の結果だけ。
  var listed: [Int] = []
  /// 結び付けるタスクを選ぶ状態の一覧か（`pick` からは決めない——選ぶ状態の間もタスクのタブの一覧を組み直すため）。
  let picking: Bool
}

/// ⌘⇧X タスク画面の状態（@Observable）。タスクの値は写さずストア（唯一の正）を直接読み書きし、GitHub の値も
/// 写さず置き場（結び付いた項目は `GitHubItemCache`、open 一覧は `GitHubOpenLists`、自分は `GitHubViewer`）
/// から、agent の状態も写さず窓の索引（`WorktreeAgentActivity`・`AgentSessionTabs`）から引く。ここは一覧ごとの状態（入力・選択・
/// スクロールする先、タスクの表は載せた並びも）・タスクの絞り込みと並び・タブ・GitHub の絞り込み・焦点・編集中の下書き・
/// 右の欄の値だけを持つ。一覧の行は `TaskPaletteRows` と `TaskPaletteGitHubRows` が毎回組む。
/// タスクか一覧が変わったとき（agent の変更を含む）は `reconcile()` 1 本で選択・焦点・下書きを付け直す。
/// 提案タブの状態と手続きは `automation` が持ち、見えているタブが提案のときだけ、入力・キー・焦点をそこへ振り分ける。
@Observable final class TaskPaletteModel {
  let store: TaskStore
  let githubItems: GitHubItemCache
  let viewer: GitHubViewer
  let openLists: GitHubOpenLists
  /// GitHub タブのリポジトリを解決する基点（⌘T と同じ: 開いた workspace の選んでいるタブの cwd、無ければ
  /// workspace の root）。
  let root: String
  let agents: WorktreeAgentActivity
  /// 会話ごとのタブ（待ちの条件の会話の行）。
  let sessionTabs: AgentSessionTabs
  /// 開いた時点の workspace の写し（タスクのタブが使う）。
  let workspaces: TaskPaletteWorkspaces
  let automation: TaskPaletteAutomationModel
  let today: TaskItem.DueDate
  /// 時刻を暦日へ落とすためのタイムゾーン。
  let timeZone: TimeZone
  /// 待ちの条件の経過・「次は」を数える今（毎分の刻みの時刻を受けて返す）。preview は 1 つの固定時刻に揃える。
  let clock: (Date) -> Date

  /// タスクのタブが持つ一覧の状態。読み書きは選ぶ状態を振り分ける `taskList` を通す（選ぶ状態の間に
  /// 隠れたタブの一覧を書き換えないため、ここ以外から触れないようにしておく）。
  private var tabTaskList = TaskPaletteTaskList(picking: false) {
    didSet {
      if tabTaskList.state.selectedID != oldValue.state.selectedID { openedConditionParts = [] }
    }
  }
  /// GitHub タブが持つ一覧の状態。読み書きは `gitHubList` を通す。選択の同一性が変わると右の欄の値を既定に
  /// 戻す。
  private var tabGitHubList = ListState<TaskPaletteGitHubRowID>() {
    didSet { resetPaneIfMoved(to: tabGitHubList.selectedID) }
  }

  /// 保存したタブ。今見えているタブは `visibleTab`。
  private(set) var tab: TaskPaletteTab = .tasks
  /// タスクのタブの絞り込み（選ぶ状態と共有する）。書くのはモデル（拡張を含む）だけ。
  var filter = TaskPaletteFilter()
  /// タスクのタブの並び。書くのはモデル（拡張を含む）だけ。
  var sort = TaskPaletteSort()
  /// 開いている絞り込みのメニュー。書くのはモデル（拡張を含む）だけ。
  var openFilterMenu: TaskPaletteFilterKind?
  /// GitHub タブの絞り込みの札（オンの関係のどれかに当たる項目を出す。空は全件）。書くのはモデル（拡張を
  /// 含む）だけ。
  var githubFilters: Set<TaskGitHubFilter> = []
  /// 「さらに」で全部を出した区分。書くのはモデル（拡張を含む）だけ。
  var expandedKinds: Set<GitHubItemKind> = []
  /// 右の欄の値。書くのはモデル（拡張を含む）だけ。
  var pane = TaskGitHubPane()
  /// 選ぶ状態（自分の一覧の状態を持つ）。書くのはモデル（拡張を含む）だけ。入る・出るときは絞り込みのメニューを閉じる。
  var pick: TaskPalettePick? {
    didSet { if (pick == nil) != (oldValue == nil) { openFilterMenu = nil } }
  }
  /// キーを受ける場所。書くのはモデル（拡張を含む）だけ。一覧を離れたら絞り込みのメニューを閉じる。
  var area: TaskPaletteArea = .list {
    didSet {
      if area != oldValue { focus() }
      if area != .list { openFilterMenu = nil }
      rememberDetailPosition()
    }
  }
  /// 編集中の文字の項目。編集中かどうかはこれだけが持つ。書くのはモデル（拡張を含む）だけ。
  var draft: TaskEditDraft? {
    didSet { if draft?.target != oldValue?.target { focus() } }
  }
  /// 書くのはモデル（拡張を含む）だけ。
  var error: TaskPaletteError?
  /// 画面を開いている間に入力欄から最後に足したタスク（右の欄の見出し「タスク · 今 ⌘⇧X から足した」）。書くのは
  /// モデル（拡張を含む）だけ。
  var justAdded: Int?
  /// 右の欄の待ちの条件の箱で開いている部分。画面が持ち、別のタスクを選ぶと閉じる。書くのはモデル（拡張を含む）だけ。
  var openedConditionParts: Set<TaskConditionPart> = []
  /// 右の欄で居る場所が最後に居た位置（そのタスクの止まる場所の並びでの番号）。
  private var detailPosition = 0
  /// focus トリガ。進めると SwiftUI が `focusTarget` を `@FocusState` へ写す。
  private(set) var focusToken = 0

  var onDismiss: () -> Void = {}
  /// 結び付いた項目の GitHub のページを開く。
  var onOpenURL: (URL) -> Void = { _ in }
  /// そのタスクのための ⌘T を開く（タスクの ID）。
  var onOpenWorktreePalette: (Int) -> Void = { _ in }
  /// agent のタブへ移る（タブの ID）。
  var onFocusTab: (Int) -> Void = { _ in }
  /// 解けた待ちの会話を続きから始める（タスクの ID）。届けられなかった理由を返す。
  var onContinueWait: (Int) -> TaskPaletteError? = { _ in nil }
  /// 解けた待ちを続きから始められない理由（タスクの ID。nil は始められる）。
  var continuationBlock: (Int) -> TaskPaletteError? = { _ in nil }
  /// 秘書の係へ頼む（agent に任せる）。受けなければ断りを返す。
  var onAskSecretary: (SecretaryAsk) -> Secretary.Refusal? = { _ in .claudeMissing }

  /// 開いた時点で、出ている行の結び付きの値を取り直す（届くまでは前回の答えで描く）。GitHub タブの一覧の
  /// 取り直し（`openLists.open(root:)`）は開く側が呼ぶ。`workspaces` は今の workspace の値を返す口で、タスクのタブは
  /// 開いた時点の写しを、提案タブは口そのものを使う。
  init(
    store: TaskStore, githubItems: GitHubItemCache, viewer: GitHubViewer,
    openLists: GitHubOpenLists, root: String, agents: WorktreeAgentActivity,
    sessionTabs: AgentSessionTabs, automations: AutomationRunner,
    workspaces: @escaping () -> TaskPaletteWorkspaces, now: Date, timeZone: TimeZone,
    clock: @escaping (Date) -> Date = { $0 }
  ) {
    self.store = store
    self.githubItems = githubItems
    self.viewer = viewer
    self.openLists = openLists
    self.root = root
    self.agents = agents
    self.sessionTabs = sessionTabs
    self.workspaces = workspaces()
    self.timeZone = timeZone
    self.clock = clock
    let today = TaskItem.DueDate.today(now, timeZone: timeZone)
    self.today = today
    automation = TaskPaletteAutomationModel(
      runner: automations, tasks: store, workspaces: workspaces, today: today,
      timeZone: timeZone)
    automation.onPlaceChange = { [weak self] in self?.focus() }
    automation.onOpenTask = { [weak self] in self?.openAgent(forTask: $0) }
    automation.onOpenURL = { [weak self] in self?.onOpenURL($0) }
    reconcile()
    githubItems.refresh(visibleLinkIDs)
  }

  /// タスクのタブの行（見えていなくても組む——タブを行き来しても選んだ行が残るよう、付け直しは自分の行で行う）。
  var rows: [TaskPaletteRow] { TaskPaletteRows.build(rowsInput) }

  /// タスクのタブの行で使う一覧の状態（タスクを選ぶ状態なら、その状態が持つもの）。
  var taskList: TaskPaletteTaskList {
    get {
      if case .task(_, let list) = pick { return list }
      return tabTaskList
    }
    set {
      if case .task(let link, _) = pick {
        pick = .task(for: link, list: newValue)
      } else {
        tabTaskList = newValue
      }
    }
  }

  /// リストの更新（絞り込み・並びの変化）。絞り込みと並びはタスクのタブと選ぶ状態が共有するので、両方の一覧を
  /// 組み直す——見えている方だけだと、抜けた後の表が古い絞り込みと並びのまま残る。選択は、見えている一覧は
  /// `selectingFirst` なら先頭の行を選ぶ。それ以外（見えていない一覧も）は、選んでいた行が組み直した表に残れば
  /// そのまま、消えていれば先頭の行を選ぶ——並びが変わった後の同じ位置は関係のない行で、次の space がそこに当たるため。
  func relist(selectingFirst: Bool) {
    if case .task(let link, var list) = pick {
      relist(&list, selectingFirst: selectingFirst)
      pick = .task(for: link, list: list)
      relist(&tabTaskList, selectingFirst: false)
    } else {
      relist(&tabTaskList, selectingFirst: selectingFirst)
    }
    reconcile()
  }

  private func relist(_ list: inout TaskPaletteTaskList, selectingFirst: Bool) {
    list.listed = []
    list.listed = TaskPaletteRows.listing(rowsInput(for: list))
    let ids = selectableIDs(for: list)
    if !selectingFirst, let id = list.state.selectedID, ids.contains(id) {
      list.state.reconcile(ids)
      list.state.follow()
    } else {
      list.state.selectFirst(in: ids)
    }
  }

  /// GitHub タブの行で使う一覧の状態（項目を選ぶ状態なら、その状態が持つもの）。
  var gitHubList: ListState<TaskPaletteGitHubRowID> {
    get {
      if case .item(_, let list) = pick { return list }
      return tabGitHubList
    }
    set {
      if case .item(let task, _) = pick {
        pick = .item(for: task, list: newValue)
      } else {
        tabGitHubList = newValue
      }
    }
  }

  var counts: TaskPaletteCounts { TaskPaletteCounts(store.tasks) }

  var rowsInput: TaskPaletteRows.Input { rowsInput(for: taskList) }

  func rowsInput(for list: TaskPaletteTaskList) -> TaskPaletteRows.Input {
    TaskPaletteRows.Input(
      tasks: store.tasks, query: list.state.query, picking: list.picking, filter: filter,
      sort: sort, listed: list.listed, workspaces: workspaces, today: today,
      timeZone: timeZone, items: githubItems.answers, viewerLogin: viewer.login,
      agents: agents.agents)
  }

  /// 出ている行（今の絞り込み・並び・入力で表に出るタスク）の結び付きの項目。GitHub の値を取りに行く範囲は
  /// これで決まる。
  var visibleLinkIDs: Set<GitHubItemID> {
    let ids = Set(
      rows.compactMap { row -> Int? in if case .task(let task) = row { task.id } else { nil } })
    return Set(store.tasks.filter { ids.contains($0.id) }.flatMap { $0.links.map(\.item) })
  }

  /// 出ている行の結び付きが変わったとき（agent の変更・絞り込み・入力）、この開いている間に
  /// まだ取りに行っていない項目を取る。
  func ensureVisibleItems() {
    githubItems.ensure(visibleLinkIDs)
  }

  var selectableIDs: [TaskPaletteRowID] { selectableIDs(for: taskList) }

  /// 選べる行（入力があれば先頭に入力の行き先、続いて表の行）。
  func selectableIDs(for list: TaskPaletteTaskList) -> [TaskPaletteRowID] {
    let input = rowsInput(for: list)
    return (TaskPaletteRows.addTitle(input) == nil ? [] : [.add])
      + TaskPaletteRows.build(input).compactMap(\.selectableID)
  }

  /// そのタスクを、絞り込みと入力に合わなくても並びの規則の位置へ載せて選ぶ（足した直後・「タスクへ移る」・ピル）。
  func selectTask(_ id: Int) {
    taskList.listed = TaskPaletteRows.listing(rowsInput, including: id)
    taskList.state.select(.task(id), in: selectableIDs)
  }

  /// 先頭の行を選ぶ（入力・絞り込みが変わったとき）。
  func selectFirstTask() {
    taskList.state.selectFirst(in: selectableIDs)
  }

  var selectedID: TaskPaletteRowID? { taskList.state.selectedID }

  /// 一覧をスクロールする先。人の操作（選び直し・絞り込みや並びの切り替え・画面からの変異）のたびに決め直す。
  var scrollTarget: ListScrollTarget<TaskPaletteRowID>? { taskList.state.scrollTarget }

  /// 選んでいるタスク（右の欄に出すもの）。入力の行き先では nil。
  var selectedTask: TaskItem? {
    guard case .task(let id) = selectedID else { return nil }
    return store.tasks.first { $0.id == id }
  }

  var focusTarget: TaskPaletteFocusTarget {
    if visibleTab == .automation { return automation.place == .proposals ? .field : .card }
    switch draft?.target {
    case .task(_, let field): return .edit(field)
    case .paneDue: return .paneDue
    case nil: return area == .list ? .field : .card
    }
  }

  /// 編集中の文字（入力欄の binding）。編集中でなければ書き込みを捨てる。
  var draftText: String {
    get { draft?.text ?? "" }
    set { draft?.text = newValue }
  }

  func focus() { focusToken &+= 1 }

  /// タスク・一覧・絞り込み・並び・タブが変わったあとの付け直し。タスクの表は組んだ並びを載せた並びとして覚え、
  /// 選択は一覧の状態ごとに、その行で付け直す（`ListState`）。右の欄に居る間に選択が別の行へ移ったら一覧へ戻り、
  /// 対象が消えた下書きは捨てる。右の欄に居る間に、選択の同一性が変わった・選んだ行が結び付いていない項目で
  /// なくなったら一覧へ戻る。
  func reconcile() {
    endStalePick()
    let previous = selectedID
    taskList.listed = TaskPaletteRows.listing(rowsInput)
    taskList.state.reconcile(selectableIDs)
    revealHiddenGitHubSelection()
    gitHubList.reconcile(gitHubSelectableIDs)
    if let id = draft?.taskID, !store.tasks.contains(where: { $0.id == id }) {
      draft = nil
    }
    reconcilePane()
    if case .detail = area, selectedID != previous || selectedTask == nil {
      leaveEditing()
      area = .list
    }
    if case .detail(let stop) = area, let task = selectedTask {
      let stops = detailStops(task)
      if !stops.contains(stop) { area = .detail(stops[min(detailPosition, stops.count - 1)]) }
    }
    rememberDetailPosition()
  }

  /// 右の欄で居る場所の位置を覚え直す。焦点の結び付きが外れたとき、同じ位置の止まる場所へ移すため。
  private func rememberDetailPosition() {
    guard case .detail(let stop) = area, let task = selectedTask,
      let index = detailStops(task).firstIndex(of: stop)
    else { return }
    detailPosition = index
  }

  func move(_ direction: Int) {
    error = nil
    switch visibleTab {
    case .tasks: taskList.state.move(direction, in: selectableIDs)
    case .github: gitHubList.move(direction, in: gitHubSelectableIDs)
    case .automation: automation.moveProposal(direction)
    }
  }

  /// 先頭（direction < 0）か末尾へ。
  func jump(_ direction: Int) {
    error = nil
    switch visibleTab {
    case .tasks: taskList.state.jump(direction, in: selectableIDs)
    case .github: gitHubList.jump(direction, in: gitHubSelectableIDs)
    case .automation: automation.jumpProposal(direction)
    }
  }

  /// 行のクリック。入力の行き先は足し、タスクの行は選ぶ。編集中なら確定してから移る。
  func tapRow(_ id: TaskPaletteRowID) {
    leaveEditingForAction()
    area = .list
    guard taskList.state.select(id, in: selectableIDs) else { return }
    focus()
    if id == .add { addFromQuery() }
  }

  /// ホバー開始による選択の追従。実マウス移動の後、一覧に居る間だけ効く。
  func hoverSelect(_ id: TaskPaletteRowID) {
    guard area == .list, draft == nil, inputModality == .pointer else { return }
    taskList.state.hoverSelect(id, in: selectableIDs)
  }

  /// ↵。選んでいる行の操作（タスクのタブは追加 / 完了 ⇄ 未着手、GitHub タブは `submitGitHub`、提案タブは
  /// タスクにする、選ぶ状態は `confirmPick`）。
  func submit() {
    guard pick == nil else { return confirmPick() }
    if visibleTab == .automation { return automation.accept() }
    guard visibleTab == .tasks else { return submitGitHub() }
    switch selectedID {
    case .add: addFromQuery()
    case .task(let id): toggleDone(id)
    case nil: break
    }
  }

  /// 別の操作に移る前の共通の手順。前の操作の失敗を消してから、編集中の文字を確定する——この順なので、
  /// 確定できずに捨てた入力の理由はフッターに残る。
  func leaveEditingForAction() {
    error = nil
    automation.clearError()
    leaveEditing()
  }

  /// タブのクリック・⇥・⇧⇥。選ぶ状態の間は切り替えない。
  func setTab(_ tab: TaskPaletteTab) {
    guard pick == nil, tab != self.tab else { return }
    leaveEditingForAction()
    area = .list
    openFilterMenu = nil
    self.tab = tab
    reconcile()
    focus()
  }

  /// 結び付いている行の ↵・メニューバーのタスクのピル。タスクのタブへ移り、そのタスクを選ぶ（選ぶ状態ならやめる）。
  /// 絞り込みと入力は変えず、合わなくても表に入れて選ぶ。
  func showTask(_ id: Int) {
    guard store.tasks.contains(where: { $0.id == id }) else { return }
    leaveEditingForAction()
    pick = nil
    area = .list
    tab = .tasks
    openFilterMenu = nil
    reconcile()
    selectTask(id)
  }
}
