import Foundation
import Observation

/// ヘッダーのタブ。GitHub は器だけで、本体は空。
enum TaskPaletteTab: Equatable {
  case tasks, github
}

/// 詳細の項目（上から並ぶ順）。
enum TaskDetailField: CaseIterable, Equatable, Hashable {
  case title, status, waiting, priority, due, workspace, memo

  /// ↵ で編集を始める文字の項目。
  var isText: Bool {
    switch self {
    case .title, .waiting, .due, .memo: true
    case .status, .priority, .workspace: false
    }
  }
}

/// 詳細で ↑↓ で止まる場所。固定の項目と、タスクごとに数が変わる結び付きの行。結び付きは位置でなく項目の
/// 同一性で持つ（agent が結び付きを変えても、焦点が別の項目へずれない）。
enum TaskDetailStop: Hashable {
  case field(TaskDetailField)
  case link(GitHubItemID)
}

/// キーを受ける場所（入力欄の一覧か、詳細の止まる場所か）。詳細の編集中かは `draft` が持つ。
enum TaskPaletteArea: Equatable {
  case list
  case detail(TaskDetailStop)
}

/// SwiftUI の焦点の宛先。モデルから一方向に写す。
enum TaskPaletteFocusTarget: Hashable {
  /// ヘッダーの入力欄。
  case field
  /// カードの器（詳細の項目にいる間）。
  case card
  /// 詳細の文字の項目の入力欄。
  case edit(TaskDetailField)
}

/// 詳細の文字の項目の下書き。編集を始めたときの対象に結び付き、確定はその ID へ書く。
struct TaskEditDraft: Equatable {
  let field: TaskDetailField
  let taskID: Int
  /// 編集を始めたときの値。打っていない下書きは確定しても書かない（その間の agent の変更を、触った
  /// だけの古い値で上書きしない）。
  let original: String
  var text: String
}

/// フッターに赤で出す失敗。画面が「何をしようとしたか」から選ぶ（ストアのエラーの文は読まない）。
enum TaskPaletteError: Error, Equatable {
  case title, waiting, due, failed
}

/// ⌘⇧X タスク画面の状態（@Observable）。タスクの値は写さずストア（唯一の正）を直接読み書きし、GitHub の値も
/// 写さず置き場（`GitHubItemCache`）から引く。ここは入力・範囲・タブ・選択・焦点・編集中の下書きだけを持つ。
/// 一覧の行は `TaskPaletteRows` が毎回組む。列が変わったとき（agent の変更を含む）は `reconcile()` 1 本で
/// 選択・焦点・下書きを付け直す。
@Observable final class TaskPaletteModel {
  let store: TaskStore
  let githubItems: GitHubItemCache
  let workspaces: TaskPaletteWorkspaces
  let today: TaskItem.DueDate
  /// 時刻を暦日へ落とすためのタイムゾーン。
  let timeZone: TimeZone

  /// ヘッダーの入力（タスクのタイトルの絞り込みと、追加するタイトル）。
  var query = "" {
    didSet {
      guard query != oldValue else { return }
      queryChanged()
    }
  }
  private(set) var scope: TaskPaletteScope = .all
  private(set) var tab: TaskPaletteTab = .tasks
  private(set) var doneExpanded = false
  /// キーを受ける場所。書くのはモデル（拡張を含む）だけ。
  var area: TaskPaletteArea = .list {
    didSet {
      if area != oldValue { focus() }
      rememberDetailPosition()
    }
  }
  /// 編集中の文字の項目。編集中かどうかはこれだけが持つ。書くのはモデル（拡張を含む）だけ。
  var draft: TaskEditDraft? {
    didSet { if draft?.field != oldValue?.field { focus() } }
  }
  /// 書くのはモデル（拡張を含む）だけ。
  var error: TaskPaletteError?
  /// 選択は行の同一性で持つ。位置は付け直しのときだけ使う。
  private var selection = ModalSelection<TaskPaletteRowID?>(nil)
  /// 選択が最後に居た位置（選べる行の並びでの番号）。
  private var selectedPosition = 0
  /// 詳細で居る場所が最後に居た位置（そのタスクの止まる場所の並びでの番号）。
  private var detailPosition = 0
  /// focus トリガ。進めると SwiftUI が `focusTarget` を `@FocusState` へ写す。
  private(set) var focusToken = 0

  var onDismiss: () -> Void = {}
  /// 結び付いた項目の GitHub のページを開く。
  var onOpenURL: (URL) -> Void = { _ in }

  /// 開いた時点で、出ている行の結び付きの値を取り直す（届くまでは前回の答えで描く）。
  init(
    store: TaskStore, githubItems: GitHubItemCache, workspaces: TaskPaletteWorkspaces, now: Date,
    timeZone: TimeZone
  ) {
    self.store = store
    self.githubItems = githubItems
    self.workspaces = workspaces
    self.timeZone = timeZone
    today = .today(now, timeZone: timeZone)
    reconcile()
    githubItems.refresh(visibleLinkIDs)
  }

  var rows: [TaskPaletteRow] {
    guard tab == .tasks else { return [] }
    return TaskPaletteRows.build(rowsInput)
  }

  var counts: TaskPaletteCounts { TaskPaletteRows.counts(rowsInput) }

  private var rowsInput: TaskPaletteRows.Input {
    TaskPaletteRows.Input(
      tasks: store.tasks, query: query, scope: scope, doneExpanded: doneExpanded,
      workspaces: workspaces, today: today, timeZone: timeZone, items: githubItems.answers,
      viewerLogin: githubItems.viewerLogin)
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

  private var selectableIDs: [TaskPaletteRowID] { rows.compactMap(\.selectableID) }

  var selectedID: TaskPaletteRowID? { selection.value }

  /// 選んでいるタスク（詳細に出すもの）。追加の行・完了の見出しでは nil。
  var selectedTask: TaskItem? {
    guard case .task(let id) = selectedID else { return nil }
    return store.tasks.first { $0.id == id }
  }

  var focusTarget: TaskPaletteFocusTarget {
    if let draft { return .edit(draft.field) }
    return area == .list ? .field : .card
  }

  /// 編集中の文字（入力欄の binding）。編集中でなければ書き込みを捨てる。
  var draftText: String {
    get { draft?.text ?? "" }
    set { draft?.text = newValue }
  }

  /// 実マウス移動（`MouseMovedDetector`）が `.pointer` へ落とす。
  var inputModality: InputModality {
    get { selection.modality }
    set { selection.modality = newValue }
  }

  func focus() { focusToken &+= 1 }

  /// 列・範囲・タブ・開閉が変わったあとの付け直し。選択の同一性が今の行にあれば位置を覚え直し、無ければ
  /// 覚えている位置（末尾で頭打ち）の行へ移す。詳細に居る間に選択が別の行へ移ったら一覧へ戻り、対象が
  /// 消えた下書きは捨てる。裏の変化はユーザーの意図ではないので入力モダリティは動かさない。
  func reconcile() {
    let previous = selection.value
    let ids = selectableIDs
    if let id = previous, let index = ids.firstIndex(of: id) {
      selectedPosition = index
    } else if ids.isEmpty {
      selection.restore(nil)
      selectedPosition = 0
    } else {
      selectedPosition = min(selectedPosition, ids.count - 1)
      selection.restore(ids[selectedPosition])
    }
    if let draft, !store.tasks.contains(where: { $0.id == draft.taskID }) {
      self.draft = nil
    }
    if case .detail = area, selection.value != previous || selectedTask == nil {
      leaveEditing()
      area = .list
    }
    if case .detail(let stop) = area, let task = selectedTask {
      let stops = Self.detailStops(task)
      if !stops.contains(stop) { area = .detail(stops[min(detailPosition, stops.count - 1)]) }
    }
    rememberDetailPosition()
  }

  /// 詳細で居る場所の位置を覚え直す。焦点の結び付きが外れたとき、同じ位置の止まる場所へ移すため。
  private func rememberDetailPosition() {
    guard case .detail(let stop) = area, let task = selectedTask,
      let index = Self.detailStops(task).firstIndex(of: stop)
    else { return }
    detailPosition = index
  }

  func move(_ direction: Int) {
    error = nil
    let ids = selectableIDs
    guard !ids.isEmpty else { return }
    let current = selectedID.flatMap { ids.firstIndex(of: $0) } ?? selectedPosition
    select(at: (current + direction + ids.count) % ids.count, in: ids)
  }

  /// 先頭（direction < 0）か末尾へ。
  func jump(_ direction: Int) {
    error = nil
    let ids = selectableIDs
    guard !ids.isEmpty else { return }
    select(at: direction < 0 ? 0 : ids.count - 1, in: ids)
  }

  /// 行のクリック。追加の行は追加し、完了の見出しは開閉し、タスクの行は選ぶ。編集中なら確定してから移る。
  func tapRow(_ id: TaskPaletteRowID) {
    leaveEditingForAction()
    area = .list
    let ids = selectableIDs
    guard let index = ids.firstIndex(of: id) else { return }
    select(at: index, in: ids)
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
    let ids = selectableIDs
    guard let index = ids.firstIndex(of: id) else { return }
    selection.hoverSelect(id)
    selectedPosition = index
  }

  private func select(at index: Int, in ids: [TaskPaletteRowID]) {
    selection.value = ids[index]
    selectedPosition = index
  }

  /// 入力が変わったら、先頭の行（入力があれば追加の行）を選ぶ。
  private func queryChanged() {
    error = nil
    let ids = selectableIDs
    if ids.isEmpty {
      selection.value = nil
      selectedPosition = 0
    } else {
      select(at: 0, in: ids)
    }
  }

  /// ↵。選んでいる行の操作（追加 / 完了 ⇄ 未着手 / 完了の欄の開閉）。
  func submit() {
    guard tab == .tasks else { return }
    switch selectedID {
    case .add: addFromQuery()
    case .task(let id): toggleDone(id)
    case .doneHeader: toggleDoneExpanded()
    case nil: break
    }
  }

  /// 入力のタイトルで、開いた workspace に付いた未着手のタスクを列の末尾へ足し、入力を空にして選ぶ。
  func addFromQuery() {
    let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard tab == .tasks, !title.isEmpty else { return }
    do {
      let item = try store.add(TaskDraft(title: title, workspace: workspaces.opened.id))
      query = ""
      let ids = selectableIDs
      if let index = ids.firstIndex(of: .task(item.id)) { select(at: index, in: ids) }
    } catch {
      self.error = .title
    }
  }

  /// 完了 ⇄ 未着手。選んでいるタスクなら、選択は同一性を捨てて同じ位置の行へ移る（完了の欄が開いて
  /// いても追わない）。選んでいないタスク（行のアイコンのクリック）なら、選択はそのまま動かない。
  func toggleDone(_ id: Int) {
    leaveEditingForAction()
    guard let task = store.tasks.first(where: { $0.id == id }) else { return reconcile() }
    var update = TaskUpdate()
    update.status = task.status == .done ? .todo : .done
    if selectedID == .task(id) { selection.restore(nil) }
    mutate(.failed) { () throws(TaskStoreError) in _ = try store.update(id, update) }
  }

  /// 確認なしで消す。選択は同じ位置の行へ移る。
  func delete(_ id: Int) {
    leaveEditingForAction()
    selection.restore(nil)
    mutate(.failed) { () throws(TaskStoreError) in try store.delete(id) }
  }

  /// ⌥↑↓。選んだタスクを、同じ欄の見えている隣のタスクと入れ替える。欄の端と完了のタスクでは何もしない。
  func reorder(_ direction: Int) {
    error = nil
    guard let task = selectedTask, task.status != .done else { return }
    let siblings = rows.compactMap { row -> Int? in
      guard case .task(let item) = row,
        store.tasks.first(where: { $0.id == item.id })?.status == task.status
      else { return nil }
      return item.id
    }
    guard let index = siblings.firstIndex(of: task.id), siblings.indices.contains(index + direction)
    else { return }
    let anchor = siblings[index + direction]
    mutate(.failed) { () throws(TaskStoreError) in
      try store.move(task.id, direction < 0 ? .before : .after, anchor)
    }
  }

  func toggleDoneExpanded() {
    error = nil
    flipDoneExpanded()
  }

  private func flipDoneExpanded() {
    doneExpanded.toggle()
    reconcile()
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
  }

  func setScope(_ scope: TaskPaletteScope) {
    guard scope != self.scope else { return }
    toggleScope()
  }

  /// ⇧⇥・タブのクリック。
  func toggleTab() {
    leaveEditingForAction()
    area = .list
    tab = tab == .tasks ? .github : .tasks
    reconcile()
  }

  func setTab(_ tab: TaskPaletteTab) {
    guard tab != self.tab else { return }
    toggleTab()
  }

  /// ストアの変異を呼び、付け直す。消えていたタスクは表に出さず付け直しに任せる。
  func mutate(_ failure: TaskPaletteError, _ body: () throws(TaskStoreError) -> Void) {
    do throws(TaskStoreError) {
      try body()
    } catch .invalid {
      error = failure
    } catch {
    }
    reconcile()
  }
}
