import Foundation
import Observation

/// ヘッダーのタブ。
enum TaskPaletteTab: Equatable {
  case tasks, github
}

/// フッターに赤で出す失敗。画面が「何をしようとしたか」から選ぶ（ストアのエラーの文は読まない）。
enum TaskPaletteError: Error, Equatable {
  case title, waiting, due, failed
  /// GitHub に自分をアサイン・レビュアーにする書き込みが失敗した。
  case assign
  /// 結び付け・付け替え・タスクにするを、ストアが受け付けなかった。
  case link
}

/// ⌘⇧X タスク画面の状態（@Observable）。タスクの値は写さずストア（唯一の正）を直接読み書きし、GitHub の値も
/// 写さず置き場（結び付いた項目は `GitHubItemCache`、open 一覧は `GitHubOpenLists`、自分は `GitHubViewer`）
/// から、agent の状態も写さず窓の索引（`WorktreeAgentActivity`）から引く。ここは一覧ごとの状態（入力・選択・
/// 送り先）・範囲・タブ・絞り込み・焦点・編集中の下書き・右の欄の値・行の掴みだけを持つ。一覧の行は
/// `TaskPaletteRows` と `TaskPaletteGitHubRows` が毎回組む。
/// 列か一覧が変わったとき（agent の変更を含む）は `reconcile()` 1 本で選択・焦点・下書き・掴みを付け直す。
@Observable final class TaskPaletteModel {
  let store: TaskStore
  let githubItems: GitHubItemCache
  let viewer: GitHubViewer
  let openLists: GitHubOpenLists
  /// 開いた workspace の root（GitHub タブのリポジトリを解決する場所）。
  let root: String
  let agents: WorktreeAgentActivity
  let workspaces: TaskPaletteWorkspaces
  let today: TaskItem.DueDate
  /// 時刻を暦日へ落とすためのタイムゾーン。
  let timeZone: TimeZone

  /// タスクのタブの一覧の状態。書くのはモデル（拡張を含む）だけ。
  var tasksList = TaskPaletteListState<TaskPaletteRowID>()
  /// GitHub タブの一覧の状態。選択の同一性が変わると右の欄の値を既定に戻す。書くのはモデル（拡張を含む）だけ。
  var githubList = TaskPaletteListState<TaskPaletteGitHubRowID>() {
    didSet { resetPaneIfMoved() }
  }

  /// ヘッダーの入力（今見えている一覧の絞り込み。タスクのタブでは追加するタイトルも兼ねる）。
  var query: String {
    get { visibleTab == .tasks ? taskList.query : gitHubList.query }
    set {
      guard newValue != query else { return }
      switch visibleTab {
      case .tasks: taskList.query = newValue
      case .github: gitHubList.query = newValue
      }
      queryChanged()
    }
  }
  private(set) var scope: TaskPaletteScope = .all
  /// 保存したタブ。今見えているタブは `visibleTab`。
  private(set) var tab: TaskPaletteTab = .tasks
  private(set) var doneExpanded = false
  /// GitHub タブの絞り込みの札。書くのはモデル（拡張を含む）だけ。
  var githubFilter: TaskGitHubFilter = .all
  /// 「さらに」で全部を出した区分。書くのはモデル（拡張を含む）だけ。
  var expandedKinds: Set<GitHubItemKind> = []
  /// 右の欄の値。書くのはモデル（拡張を含む）だけ。
  var pane = TaskGitHubPane()
  /// 選ぶ状態（自分の一覧の状態を持つ）。書くのはモデル（拡張を含む）だけ。
  var pick: TaskPalettePick?
  /// キーを受ける場所。書くのはモデル（拡張を含む）だけ。
  var area: TaskPaletteArea = .list {
    didSet {
      if area != oldValue { focus() }
      rememberDetailPosition()
    }
  }
  /// 編集中の文字の項目。編集中かどうかはこれだけが持つ。書くのはモデル（拡張を含む）だけ。
  var draft: TaskEditDraft? {
    didSet { if draft?.target != oldValue?.target { focus() } }
  }
  /// 書くのはモデル（拡張を含む）だけ。
  var error: TaskPaletteError?
  /// 一覧の行の掴み。書くのはモデル（拡張を含む）だけ。
  var drag: TaskPaletteDrag = .idle
  /// 詳細で居る場所が最後に居た位置（そのタスクの止まる場所の並びでの番号）。
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

  /// 開いた時点で、出ている行の結び付きの値を取り直す（届くまでは前回の答えで描く）。GitHub タブの一覧の
  /// 取り直し（`openLists.open(root:)`）は開く側が呼ぶ。
  init(
    store: TaskStore, githubItems: GitHubItemCache, viewer: GitHubViewer,
    openLists: GitHubOpenLists, root: String, agents: WorktreeAgentActivity,
    workspaces: TaskPaletteWorkspaces, now: Date, timeZone: TimeZone
  ) {
    self.store = store
    self.githubItems = githubItems
    self.viewer = viewer
    self.openLists = openLists
    self.root = root
    self.agents = agents
    self.workspaces = workspaces
    self.timeZone = timeZone
    today = .today(now, timeZone: timeZone)
    reconcile()
    githubItems.refresh(visibleLinkIDs)
  }

  /// 今見えているタブ。選ぶ状態ならその方向で、無ければ保存したタブ。行・キー・フッター・本体の切り替えは
  /// すべてこれを見る。
  var visibleTab: TaskPaletteTab {
    switch pick {
    case .task: .tasks
    case .item: .github
    case nil: tab
    }
  }

  /// タスクのタブの行（見えていなくても組む——タブを行き来しても選んだ行が残るよう、付け直しは自分の行で行う）。
  var rows: [TaskPaletteRow] { TaskPaletteRows.build(rowsInput) }

  /// タスクのタブの行で使う一覧の状態（タスクを選ぶ状態なら、その状態が持つもの）。
  var taskList: TaskPaletteListState<TaskPaletteRowID> {
    get {
      if case .task(_, let list) = pick { return list }
      return tasksList
    }
    set {
      if case .task(let link, _) = pick {
        pick = .task(for: link, list: newValue)
      } else {
        tasksList = newValue
      }
    }
  }

  /// GitHub タブの行で使う一覧の状態（項目を選ぶ状態なら、その状態が持つもの）。
  var gitHubList: TaskPaletteListState<TaskPaletteGitHubRowID> {
    get {
      if case .item(_, let list) = pick { return list }
      return githubList
    }
    set {
      if case .item(let task, _) = pick {
        pick = .item(for: task, list: newValue)
      } else {
        githubList = newValue
      }
    }
  }

  var counts: TaskPaletteCounts { TaskPaletteRows.counts(rowsInput) }

  private var rowsInput: TaskPaletteRows.Input {
    TaskPaletteRows.Input(
      tasks: store.tasks, query: taskList.query, addsRow: pick == nil, scope: scope,
      doneExpanded: doneExpanded,
      workspaces: workspaces, today: today, timeZone: timeZone, items: githubItems.answers,
      viewerLogin: viewer.login, agents: agents.agents)
  }

  /// 出ている行（今の範囲・入力で一覧に出るタスク。完了の欄は開いているときだけ）の結び付きの項目。
  /// GitHub の値を取りに行く範囲はこれで決まる。
  var visibleLinkIDs: Set<GitHubItemID> {
    let ids = Set(
      rows.compactMap { row -> Int? in if case .task(let task) = row { task.id } else { nil } })
    return Set(store.tasks.filter { ids.contains($0.id) }.flatMap { $0.links.map(\.item) })
  }

  /// 出ている行の結び付きが変わったとき（agent の変更・完了の欄の開閉・範囲・入力）、この開いている間に
  /// まだ取りに行っていない項目を取る。
  func ensureVisibleItems() {
    githubItems.ensure(visibleLinkIDs)
  }

  var selectableIDs: [TaskPaletteRowID] { rows.compactMap(\.selectableID) }

  var selectedID: TaskPaletteRowID? { taskList.selectedID }

  /// 一覧を送る先。人の操作（選び直し・並べ替え・範囲や開閉の切り替え・画面からの変異）のたびに決め直す。
  var scrollTarget: TaskPaletteScrollTarget<TaskPaletteRowID>? { taskList.scrollTarget }

  /// 選んでいるタスク（詳細に出すもの）。追加の行・完了の見出しでは nil。
  var selectedTask: TaskItem? {
    guard case .task(let id) = selectedID else { return nil }
    return store.tasks.first { $0.id == id }
  }

  var focusTarget: TaskPaletteFocusTarget {
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

  /// 実マウス移動（`MouseMovedDetector`）が `.pointer` へ落とす。
  var inputModality: InputModality {
    get { visibleTab == .tasks ? taskList.modality : gitHubList.modality }
    set {
      switch visibleTab {
      case .tasks: taskList.modality = newValue
      case .github: gitHubList.modality = newValue
      }
    }
  }

  func focus() { focusToken &+= 1 }

  /// 列・一覧・範囲・タブ・開閉が変わったあとの付け直し。選択は一覧の状態ごとに、その行で付け直す
  /// （`TaskPaletteListState`）。詳細に居る間に選択が別の行へ移ったら一覧へ戻り、対象が消えた下書きは捨て、
  /// 並びが変わった掴みも捨てる。右の欄に居る間に、選択の同一性が変わった・選んだ行が結び付いていない項目で
  /// なくなったら一覧へ戻る。
  func reconcile() {
    endStalePick()
    let previous = selectedID
    taskList.reconcile(selectableIDs)
    gitHubList.reconcile(gitHubSelectableIDs)
    if case .task(let id, _) = draft?.target, !store.tasks.contains(where: { $0.id == id }) {
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
    discardStaleDrag()
  }

  /// 詳細で居る場所の位置を覚え直す。焦点の結び付きが外れたとき、同じ位置の止まる場所へ移すため。
  private func rememberDetailPosition() {
    guard case .detail(let stop) = area, let task = selectedTask,
      let index = detailStops(task).firstIndex(of: stop)
    else { return }
    detailPosition = index
  }

  func move(_ direction: Int) {
    error = nil
    switch visibleTab {
    case .tasks: taskList.move(direction, in: selectableIDs)
    case .github: gitHubList.move(direction, in: gitHubSelectableIDs)
    }
  }

  /// 先頭（direction < 0）か末尾へ。
  func jump(_ direction: Int) {
    error = nil
    switch visibleTab {
    case .tasks: taskList.jump(direction, in: selectableIDs)
    case .github: gitHubList.jump(direction, in: gitHubSelectableIDs)
    }
  }

  /// 行のクリック。追加の行は追加し、完了の見出しは開閉し、タスクの行は選ぶ。編集中なら確定してから移る。
  func tapRow(_ id: TaskPaletteRowID) {
    leaveEditingForAction()
    area = .list
    guard taskList.select(id, in: selectableIDs) else { return }
    focus()
    switch id {
    case .add: addFromQuery()
    case .doneHeader: flipDoneExpanded()
    case .task: break
    }
  }

  /// ホバー開始による選択の追従。実マウス移動の後、一覧に居る間だけ効く。
  func hoverSelect(_ id: TaskPaletteRowID) {
    guard area == .list, draft == nil, inputModality == .pointer else { return }
    taskList.hoverSelect(id, in: selectableIDs)
  }

  /// 入力が変わったら、先頭の行（タスクのタブで入力があれば追加の行）を選ぶ。
  private func queryChanged() {
    error = nil
    switch visibleTab {
    case .tasks: taskList.selectFirst(in: selectableIDs)
    case .github: gitHubList.selectFirst(in: gitHubSelectableIDs)
    }
    discardStaleDrag()
  }

  /// ↵。選んでいる行の操作（タスクのタブは追加 / 完了 ⇄ 未着手 / 完了の欄の開閉、GitHub タブは
  /// `submitGitHub`、選ぶ状態は `confirmPick`）。
  func submit() {
    guard pick == nil else { return confirmPick() }
    guard visibleTab == .tasks else { return submitGitHub() }
    switch selectedID {
    case .add: addFromQuery()
    case .task(let id): toggleDone(id)
    case .doneHeader: toggleDoneExpanded()
    case nil: break
    }
  }

  func toggleDoneExpanded() {
    error = nil
    flipDoneExpanded()
  }

  private func flipDoneExpanded() {
    doneExpanded.toggle()
    reconcile()
    taskList.follow()
  }

  /// 別の操作に移る前の共通の手順。前の操作の失敗を消してから、編集中の文字を確定する——この順なので、
  /// 確定できずに捨てた入力の理由はフッターに残る。
  func leaveEditingForAction() {
    error = nil
    leaveEditing()
  }

  /// ⇥・範囲の札のクリック。
  func toggleScope() {
    leaveEditingForAction()
    area = .list
    scope = scope == .all ? .opened : .all
    reconcile()
    taskList.follow()
  }

  func setScope(_ scope: TaskPaletteScope) {
    guard scope != self.scope else { return }
    toggleScope()
  }

  /// ⇧⇥・タブのクリック。選ぶ状態の間は切り替えない。
  func toggleTab() {
    guard pick == nil else { return }
    leaveEditingForAction()
    area = .list
    tab = tab == .tasks ? .github : .tasks
    reconcile()
  }

  func setTab(_ tab: TaskPaletteTab) {
    guard tab != self.tab else { return }
    toggleTab()
  }

  /// 結び付いている行の ↵。タスクのタブへ移り、そのタスクを選ぶ。範囲・入力・完了の欄で隠れていれば、
  /// 見えるように切り替える。
  func showTask(_ id: Int) {
    guard let task = store.tasks.first(where: { $0.id == id }) else { return }
    leaveEditingForAction()
    area = .list
    tab = .tasks
    if scope == .opened, task.workspace != workspaces.opened.id { scope = .all }
    if task.status == .done { doneExpanded = true }
    if !taskList.query.isEmpty,
      !task.title.localizedStandardContains(
        taskList.query.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      taskList.query = ""
    }
    reconcile()
    taskList.select(.task(id), in: rows.compactMap(\.selectableID))
  }

  /// 画面からのストアの変異を呼び、付け直して今見えている一覧の選択へ送る。消えていたタスクは表に出さず
  /// 付け直しに任せる。
  func mutate(_ failure: TaskPaletteError, _ body: () throws(TaskStoreError) -> Void) {
    do throws(TaskStoreError) {
      try body()
    } catch .invalid {
      error = failure
    } catch {
    }
    reconcile()
    switch visibleTab {
    case .tasks: taskList.follow()
    case .github: gitHubList.follow()
    }
  }
}
