import Foundation

/// GitHub タブの右の欄の止まる場所（上から並ぶ順）。
enum TaskGitHubPaneStop: Hashable {
  /// 「自分をアサインする」（レビュアーにする）のチェック。足すものがある項目でだけ止まる。
  case assign
  case priority
  case due
}

/// 右の欄の値。結び付いていない行を「タスクにする」ときに使い、ストアには書かない。選択の同一性が変わると
/// 既定（オン・中・期限なし）に戻る。
struct TaskGitHubPane: Equatable {
  /// この値を打った行。
  var owner: TaskPaletteGitHubRowID?
  var assignsSelf = true
  var priority: TaskItem.Priority = .medium
  var due: TaskItem.DueDate?
}

/// GitHub タブの本体に出すもの。
enum TaskPaletteGitHubBody: Equatable {
  case lists
  case loading
  /// 前回の一覧が無いまま取得に失敗した。
  case failed
  case unavailable(GitHubRepositoryUnavailable)
}

/// GitHub タブ（開いた workspace のリポジトリの open な Issue・PR）の操作。一覧は置き場（`GitHubOpenLists`）を
/// 写さずに読み、変異はストアのメソッドをそのまま呼ぶ。
extension TaskPaletteModel {
  /// 開いた workspace のリポジトリ（解決中・使えない間は前回の答え）。
  var gitHubRepo: GitHubRepoName? { openLists.repository(for: root) }

  private var gitHubRepository: GitHubOpenLists.Repository? {
    gitHubRepo.flatMap { openLists.repositories[$0] }
  }

  /// 本体の出し方。前回の一覧があれば、解決や取り直しが失敗していてもそれを描く。
  var gitHubBody: TaskPaletteGitHubBody {
    let repository = gitHubRepository
    if repository?.issues.items != nil || repository?.pullRequests.items != nil { return .lists }
    if case .unavailable(let reason) = openLists.roots[root]?.resolution {
      return .unavailable(reason)
    }
    if let repository, repository.issues.failed || repository.pullRequests.failed,
      !repository.issues.growing, !repository.pullRequests.growing
    {
      return .failed
    }
    return .loading
  }

  /// ヘッダーのタブの件数（取れた open の件数）。まだ何も取れていなければ nil。
  var gitHubCount: Int? {
    let repository = gitHubRepository
    let issues = repository?.issues.items
    let pullRequests = repository?.pullRequests.items
    guard issues != nil || pullRequests != nil else { return nil }
    return (issues?.count ?? 0) + (pullRequests?.count ?? 0)
  }

  var gitHubRows: [TaskPaletteGitHubRow] {
    guard let input = gitHubRowsInput else { return [] }
    return TaskPaletteGitHubRows.build(input)
  }

  var gitHubFilterCounts: TaskGitHubFilterCounts? {
    gitHubRowsInput.map(TaskPaletteGitHubRows.counts)
  }

  private var gitHubRowsInput: TaskPaletteGitHubRows.Input? {
    guard let repo = gitHubRepo, gitHubBody == .lists else { return nil }
    let repository = gitHubRepository
    return TaskPaletteGitHubRows.Input(
      repo: repo, issues: repository?.issues.items ?? [],
      pullRequests: repository?.pullRequests.items ?? [], tasks: store.tasks, login: viewer.login,
      reviewRequests: repository?.reviewRequests, filter: githubFilter, query: gitHubList.query,
      expanded: expandedKinds,
      loading: Set(
        [GitHubItemKind.issue, .pr].filter { kind in
          let list = kind == .issue ? repository?.issues : repository?.pullRequests
          return list.map { $0.growing || ($0.items == nil && !$0.failed) } ?? true
        }))
  }

  var gitHubSelectableIDs: [TaskPaletteGitHubRowID] { gitHubRows.compactMap(\.selectableID) }

  var selectedGitHubID: TaskPaletteGitHubRowID? { gitHubList.selectedID }

  /// 選んでいる項目の行。「さらに」の行では nil。
  var selectedGitHubRow: TaskPaletteGitHubItemRow? {
    guard case .item(let id) = selectedGitHubID else { return nil }
    return gitHubRows.lazy.compactMap { row -> TaskPaletteGitHubItemRow? in
      if case .item(let item) = row, item.id == id { item } else { nil }
    }.first
  }

  /// 「タスクにする」で自分を足す役割（足すものが無ければ nil）。
  func selfRole(_ row: TaskPaletteGitHubItemRow) -> GitHubSelfRole? {
    TaskPaletteGitHubRows.selfRole(
      row.item, login: viewer.login, reviewRequests: gitHubRepository?.reviewRequests)
  }

  /// 項目の書き込みの失敗の記録（次に試すか成功すれば消える）。
  func writeFailure(_ id: GitHubItemID) -> GitHubSelfRole? {
    openLists.writeFailures[id]
  }

  /// 結び付いていない行の右の欄の止まる場所。
  func paneStops(_ row: TaskPaletteGitHubItemRow) -> [TaskGitHubPaneStop] {
    (selfRole(row) == nil ? [] : [.assign]) + [.priority, .due]
  }

  // MARK: - 一覧

  /// ↵。結び付いていない行はタスクにし、結び付いている行はそのタスクへ移り、「さらに」は区分を開く。
  func submitGitHub() {
    switch selectedGitHubID {
    case .item:
      guard let row = selectedGitHubRow else { return }
      if let task = row.task { showTask(task.id) } else { makeTask(row) }
    case .more(let kind): expand(kind)
    case nil: break
    }
  }

  /// 行のクリック。「さらに」は区分を開き、項目は選ぶ。編集中なら確定してから移る。
  func tapGitHubRow(_ id: TaskPaletteGitHubRowID) {
    leaveEditingForAction()
    area = .list
    guard gitHubList.select(id, in: gitHubSelectableIDs) else { return }
    focus()
    if case .more(let kind) = id { expand(kind) }
  }

  /// ホバー開始による選択の追従。実マウス移動の後、一覧に居る間だけ効く。
  func hoverGitHubRow(_ id: TaskPaletteGitHubRowID) {
    guard area == .list, draft == nil, inputModality == .pointer else { return }
    gitHubList.hoverSelect(id, in: gitHubSelectableIDs)
  }

  /// ⇥。絞り込みの札を巡回する。
  func cycleGitHubFilter() {
    setGitHubFilter(githubFilter.next)
  }

  /// 札のクリック。一覧は先頭の行から選び直す。
  func setGitHubFilter(_ filter: TaskGitHubFilter) {
    leaveEditingForAction()
    area = .list
    githubFilter = filter
    gitHubList.selectFirst(in: gitHubSelectableIDs)
  }

  /// 区分の結び付いていない行を全部出す（閉じるまで保つ）。選択は同じ位置の行（出てきた最初の行）へ移る。
  func expand(_ kind: GitHubItemKind) {
    error = nil
    expandedKinds.insert(kind)
    gitHubList.forget()
    reconcile()
    gitHubList.follow()
  }

  // MARK: - タスクにする・開く・外す

  /// 結び付いていない項目を、開いた workspace の未着手のタスクにする（右の欄の優先度と期限、主の結び付きが
  /// その項目）。行は結び付いた行として区分の上へ移り、選択はその行を追う。チェックがオンなら自分を GitHub に
  /// 裏で足す——ローカルの操作を GitHub の往復で待たせない。書き込む対象は、押した瞬間の項目の値で捕まえる。
  /// 足したタスクの ID を返す。
  @discardableResult func makeTask(_ row: TaskPaletteGitHubItemRow) -> Int? {
    guard settlePaneDue() else { return nil }
    leaveEditingForAction()
    let pane = self.pane
    let role = pane.assignsSelf ? selfRole(row) : nil
    let link = TaskLink(item: row.id, kind: row.item.kind)
    let task: TaskItem
    do {
      task = try store.add(
        TaskDraft(
          title: row.item.title, priority: pane.priority, due: pane.due,
          workspace: workspaces.opened.id, links: [link]))
    } catch {
      // 拒まれうるのは、間に agent がその項目を結び付けていたときだけ（タイトルは GitHub が 1 行に保つ）。
      self.error = .link
      reconcile()
      return nil
    }
    self.pane = TaskGitHubPane(owner: selectedGitHubID)
    area = .list
    reconcile()
    gitHubList.follow()
    if let role {
      openLists.addSelf(as: role, to: row.id, kind: link.kind) { [weak self] succeeded in
        if !succeeded { self?.error = .assign }
      }
    }
    return task.id
  }

  /// ⌘⌫（結び付いている行）。その項目だけを除いた列で置き換える。行は結び付いていない側へ戻り、選択はその行に
  /// 残る（「さらに」の内側へ戻るなら、付け直しがその区分を開く）。
  func unlinkSelectedGitHubItem() {
    guard let row = selectedGitHubRow, let owner = row.task,
      let task = store.tasks.first(where: { $0.id == owner.id })
    else { return }
    leaveEditingForAction()
    var update = TaskUpdate()
    update.links = task.links.filter { $0.item != row.id }
    mutate(.failed) { () throws(TaskStoreError) in _ = try store.update(task.id, update) }
  }

  /// 選んでいる項目が一覧に残ったまま閉じた区分の「さらに」の内側（6 件目以降）へ隠れたら、その区分を開く。
  /// 隠れたままだと付け直しが選択を同じ位置の別の項目へ移し、↵ で見ていない項目をタスクにして自分を書き込み、
  /// ⌘⌫ で別の項目の結び付きを外す。隠れる契機は人の ⌘⌫ に限らない（agent が結び付きを外す・消す、
  /// 一覧の後続のページで上位が入れ替わる）。
  func revealHiddenGitHubSelection() {
    guard case .item(let id) = gitHubList.selectedID,
      !gitHubSelectableIDs.contains(.item(id)), var input = gitHubRowsInput
    else { return }
    input.expanded = [.issue, .pr]
    for case .item(let row) in TaskPaletteGitHubRows.build(input) where row.id == id {
      expandedKinds.insert(row.item.kind)
    }
  }

  /// ⌘↵（GitHub タブ）。選んでいる項目の GitHub のページをブラウザで開く（結び付きの有無を問わない）。
  func openSelectedGitHubItemInBrowser() {
    guard let row = selectedGitHubRow else { return }
    onOpenURL(TaskLink(item: row.id, kind: row.item.kind).url)
  }

  /// ⌘T（GitHub タブ）。結び付いていない行はタスクにしてから、結び付いている行はそのタスクで、⌘T を開く。
  func openWorktreePaletteFromGitHub() {
    guard let row = selectedGitHubRow else { return }
    if let task = row.task {
      leaveEditingForAction()
      onOpenWorktreePalette(task.id)
    } else if let id = makeTask(row) {
      onOpenWorktreePalette(id)
    }
  }

  // MARK: - 右の欄

  /// →。結び付いていない行で、右の欄の先頭へ入る。
  func enterPane() {
    guard pick == nil, let row = selectedGitHubRow, row.task == nil,
      let first = paneStops(row).first
    else {
      return
    }
    error = nil
    area = .pane(first)
  }

  /// esc・選択式でない場所の ←。一覧へ戻る（期限の編集中なら確定してから）。
  func leavePane() {
    leaveEditingForAction()
    area = .list
  }

  /// ↑↓。端では止まる。
  func movePaneStop(_ direction: Int) {
    guard case .pane(let stop) = area, let row = selectedGitHubRow else { return }
    let stops = paneStops(row)
    guard let current = stops.firstIndex(of: stop), stops.indices.contains(current + direction)
    else { return }
    error = nil
    area = .pane(stops[current + direction])
  }

  /// ←→。優先度を変える。優先度でなければ false（← は一覧へ戻る合図）。
  @discardableResult func changePaneValue(_ direction: Int) -> Bool {
    guard area == .pane(.priority) else { return false }
    error = nil
    let options: [TaskItem.Priority] = [.high, .medium, .low]
    let index = options.firstIndex(of: pane.priority)!
    pane.priority = options[min(max(index + direction, 0), options.count - 1)]
    return true
  }

  func setPanePriority(_ priority: TaskItem.Priority) {
    leaveEditingForAction()
    area = .pane(.priority)
    pane.priority = priority
    focus()
  }

  /// space・チェックのクリック。
  func togglePaneAssign() {
    guard let row = selectedGitHubRow, selfRole(row) != nil else { return }
    leaveEditingForAction()
    area = .pane(.assign)
    pane.assignsSelf.toggle()
    focus()
  }

  /// 期限の ↵・クリック。編集を始める。
  func beginPaneDue() {
    guard selectedGitHubRow?.task == nil, draft == nil else { return }
    leaveEditingForAction()
    area = .pane(.due)
    let text = pane.due?.text ?? ""
    draft = TaskEditDraft(target: .paneDue, original: text, text: text)
  }

  func clearPaneDue() {
    leaveEditingForAction()
    area = .pane(.due)
    pane.due = nil
  }

  /// 右の欄の期限を編集中なら確定する。読めない文字のままなら、理由を出して編集を続け、false。
  private func settlePaneDue() -> Bool {
    guard draft?.target == .paneDue else { return true }
    return endEditing(commit: true)
  }

  /// 選択の同一性が変わったら、右の欄の値を既定に戻し（打ちかけの期限も捨てる）、欄に居たなら一覧へ戻る
  /// ——別の項目の欄に既定の値（チェックはオン）で居続けると、↵ で見ていない項目をタスクにして自分を足す。
  /// agent の変更で同じ行のままなら、打った値を保つ。
  func resetPaneIfMoved() {
    guard pane.owner != githubList.selectedID else { return }
    pane = TaskGitHubPane(owner: githubList.selectedID)
    if draft?.target == .paneDue { draft = nil }
    if case .pane = area { area = .list }
  }

  /// 右の欄に居る間に、選んだ行が結び付いていない項目でなくなったら一覧へ戻り、止まる場所が消えたら
  /// （チェックが出なくなった）残る場所へ移る。選択の同一性が変わったときは `resetPaneIfMoved` が一覧へ戻す。
  func reconcilePane() {
    guard case .pane(let stop) = area else { return }
    guard visibleTab == .github, let row = selectedGitHubRow, row.task == nil else {
      if draft?.target == .paneDue { draft = nil }
      area = .list
      return
    }
    let stops = paneStops(row)
    if !stops.contains(stop) { area = .pane(stops[0]) }
  }
}
