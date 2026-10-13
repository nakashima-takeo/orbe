import XCTest

@testable import Orbe

/// タスク画面（⌘⇧X）の表の行を、タスク・入力・絞り込み・並びから組む純関数 `TaskPaletteRows` を固定する。
///
/// 壊れると何が起きるか: 既定の並びが作成の新しい順でなくなり、`orb task list` と画面の並びが食い違う。絞り込みの外の
/// タスクが混ざる、または消える。期限で並べると期限の無いタスクが先に来て、近い期限が埋もれる。待ちの日数・workspace の値が別の値を言い、人が「今日やるもの」「自分の workspace の
/// もの」を見誤る。状態の札の件数が打った文字で揺れて、残りの量が分からなくなる。
@MainActor
final class TaskPaletteRowsTests: OrbeTestCase {
  private let calendar = DesignSceneFixtures.taskCalendar
  private let opened = TaskPaletteWorkspaces.Entry(id: UUID(), name: "orbe")
  private let other = TaskPaletteWorkspaces.Entry(id: UUID(), name: "web-app")
  private var workspaces: TaskPaletteWorkspaces {
    TaskPaletteWorkspaces(opened: opened, all: [opened, other], home: nil)
  }
  private let today = TaskItem.DueDate(year: 2025, month: 10, day: 4)!
  private var now: Date {
    calendar.date(from: DateComponents(year: 2025, month: 10, day: 4, hour: 10))!
  }

  func task(
    _ id: Int, _ title: String = "タスク", _ status: TaskItem.Status = .todo,
    _ mutate: (inout TaskItem) -> Void = { _ in }
  ) -> TaskItem {
    var item = TaskItem(
      id: id, title: title, status: status, wait: nil, priority: .medium, due: nil,
      workspace: nil, description: "", createdAt: now, createdBy: nil)
    mutate(&item)
    return item
  }

  func input(
    _ tasks: [TaskItem], query: String = "", filter: TaskPaletteFilter = TaskPaletteFilter(),
    sort: TaskPaletteSort = TaskPaletteSort(), items: [GitHubItemID: GitHubItemAnswer] = [:],
    viewerLogin: String? = nil, agents: [String: WorktreeAgentActivity.Agent] = [:]
  ) -> TaskPaletteRows.Input {
    TaskPaletteRows.Input(
      tasks: tasks, query: query, filter: filter, sort: sort,
      workspaces: workspaces, today: today, timeZone: calendar.timeZone, items: items,
      viewerLogin: viewerLogin, agents: agents)
  }

  /// どの状態も出す絞り込み。
  private var everything: TaskPaletteFilter {
    var filter = TaskPaletteFilter()
    filter.states = []
    return filter
  }

  private func taskIDs(_ rows: [TaskPaletteRow]) -> [Int] {
    rows.compactMap { if case .task(let row) = $0 { row.id } else { nil } }
  }

  func taskRow(
    _ item: TaskItem, items: [GitHubItemID: GitHubItemAnswer] = [:], viewerLogin: String? = nil
  ) throws -> TaskPaletteTaskRow {
    let rows = TaskPaletteRows.build(
      input([item], filter: everything, items: items, viewerLogin: viewerLogin))
    return try XCTUnwrap(
      rows.lazy.compactMap { if case .task(let row) = $0 { row } else { nil } }.first)
  }

  // MARK: - 並びと絞り込み

  func testRowsAreFlatNewestFirstAndHideDoneByDefault() {
    let tasks = [
      task(1, "a", .todo), task(2, "b", .inProgress), task(4, "d", .todo),
      task(5, "e", .inProgress), task(3, "c", .done),
    ]

    let rows = TaskPaletteRows.build(input(tasks))

    XCTAssertEqual(
      taskIDs(rows), [5, 4, 2, 1], "保存の順に依らず作成の新しい順（同時刻は ID の大きい方が先）。完了は既定の絞り込みで出ない")
    XCTAssertEqual(rows.count, 4, "タスクの行のほかに行は無い")
  }

  func testStateFilterIncludingDoneListsDoneTasksAmongTheOthers() {
    let tasks = [task(1, "a", .done), task(2, "b", .todo), task(3, "c", .done)]

    XCTAssertEqual(taskIDs(TaskPaletteRows.build(input(tasks, filter: everything))), [3, 2, 1])
  }

  /// workspace の「なし」には、削除された workspace への参照も当たる。
  func testFilterKindsCombineWithAndWhileValuesOfAKindCombineWithOr() {
    let tasks = [
      task(1) {
        $0.workspace = self.opened.id
        $0.priority = .high
      },
      task(2) {
        $0.workspace = self.other.id
        $0.priority = .high
      },
      task(3) { $0.priority = .low },
      task(4) {
        $0.workspace = UUID()
        $0.priority = .high
      },
      task(5) { $0.workspace = self.opened.id },
    ]
    var filter = TaskPaletteFilter()
    filter.workspaces = [opened.id, nil]
    filter.priorities = [.high, .low]

    XCTAssertEqual(taskIDs(TaskPaletteRows.build(input(tasks, filter: filter))), [4, 3, 1])
  }

  /// 期限の区切りは今日との暦日の差だけで決まる（7 日後までが「7 日以内」）。
  func testDueFilterBucketsTasksByCalendarDaysFromToday() {
    func due(_ day: Int) -> TaskItem.DueDate { TaskItem.DueDate(year: 2025, month: 10, day: day)! }
    let tasks = [
      task(1) { $0.due = due(3) }, task(2) { $0.due = due(4) }, task(3) { $0.due = due(11) },
      task(4) { $0.due = due(12) }, task(5),
    ]
    func ids(_ bucket: TaskDueBucket) -> [Int] {
      var filter = TaskPaletteFilter()
      filter.dues = [bucket]
      return taskIDs(TaskPaletteRows.build(input(tasks, filter: filter)))
    }

    XCTAssertEqual(ids(.overdue), [1])
    XCTAssertEqual(ids(.today), [2])
    XCTAssertEqual(ids(.withinWeek), [3])
    XCTAssertEqual(ids(.later), [4])
    XCTAssertEqual(ids(.none), [5])
  }

  /// 期限の無いタスクはどちらの向きでも末尾に来て、同じ値どうしは作成の新しい順（同時刻は ID の大きい方が先）。
  func testSortingByDueKeepsTasksWithoutDueLastInEitherDirection() {
    func due(_ day: Int) -> TaskItem.DueDate { TaskItem.DueDate(year: 2025, month: 10, day: day)! }
    let tasks = [
      task(1) { $0.due = due(10) }, task(2), task(3) { $0.due = due(5) },
      task(4) { $0.due = due(10) }, task(5),
    ]
    func ids(reversed: Bool) -> [Int] {
      taskIDs(
        TaskPaletteRows.build(
          input(tasks, sort: TaskPaletteSort(column: .due, reversed: reversed))))
    }

    XCTAssertEqual(ids(reversed: false), [3, 4, 1, 5, 2], "近い順")
    XCTAssertEqual(ids(reversed: true), [4, 1, 3, 5, 2], "遠い順")
  }

  /// 状態の列の既定の向きは 進行中 → 待ち → 未着手 → 完了。
  func testSortingByStateListsInProgressWaitingTodoThenDone() {
    let waiting = TaskItem.Waiting(reason: "返事", since: now)
    let tasks = [
      task(1, "a", .inProgress), task(2, "b", .done), task(3, "c", .todo),
      task(4, "d", .todo) { $0.wait = .waiting(waiting) },
    ]

    let rows = TaskPaletteRows.build(
      input(tasks, filter: everything, sort: TaskPaletteSort(column: .state)))

    XCTAssertEqual(taskIDs(rows), [1, 4, 3, 2])
  }

  func testNoTasksAndNoQueryShowsTheEmptyInfoRowOnly() {
    XCTAssertEqual(TaskPaletteRows.build(input([])), [.empty])
  }

  // MARK: - 入力の行き先

  /// 入力中は、前後の空白を除いたタイトルが入力の行き先になり、表は絞り込みに合うタスクのうち一致するものだけを並べる。
  func testQueryGivesTheTrimmedTitleToTheDestinationAndListsMatches() {
    let tasks = [
      task(1, "PR の説明を書く", .inProgress), task(2, "経費精算を出す"), task(3, "pr を見る"),
      task(4, "pr をレビューする", .done),
    ]
    let typed = input(tasks, query: "  Pr  ")

    let rows = TaskPaletteRows.build(typed)

    XCTAssertEqual(TaskPaletteRows.addTitle(typed), "Pr", "前後の空白を除いたタイトル")
    XCTAssertEqual(taskIDs(rows), [3, 1], "大文字小文字を区別せず部分一致で絞る（完了は絞り込みの外）")
  }

  func testWhitespaceOnlyQueryNeitherAddsNorFilters() {
    let typed = input([task(1, "a"), task(2, "b")], query: "   ")

    XCTAssertNil(TaskPaletteRows.addTitle(typed))
    XCTAssertEqual(taskIDs(TaskPaletteRows.build(typed)), [2, 1])
  }

  func testQueryMatchingNothingLeavesOnlyTheDestination() {
    let typed = input([task(1, "経費精算を出す")], query: "歯医者")

    XCTAssertEqual(TaskPaletteRows.addTitle(typed), "歯医者")
    XCTAssertEqual(TaskPaletteRows.build(typed), [], "表は空（「該当するタスクはありません」も出さない）")
  }

  // MARK: - 件数

  func testCountsArePerDisplayStateOverAllTasksAndUndoneTotal() {
    let waiting = TaskItem.Waiting(reason: "返事", since: now)
    let tasks = [
      task(1, "a", .todo) { $0.workspace = self.opened.id },
      task(2, "b", .inProgress) { $0.workspace = self.opened.id },
      task(3, "c", .done) { $0.workspace = self.opened.id },
      task(4, "d", .inProgress) { $0.wait = .waiting(waiting) },
      task(5, "e", .todo),
    ]

    let counts = TaskPaletteCounts(tasks)

    XCTAssertEqual(counts.states, [.todo: 2, .inProgress: 1, .waiting: 1, .done: 1])
    XCTAssertEqual(counts.undone, 4)
  }

  // MARK: - タスクの行の値

  func testStateShowsDoneOverWaitingAndWaitingOverInProgressOrTodo() throws {
    let waiting = TaskItem.Waiting(reason: "返事", since: now)

    XCTAssertEqual(try taskRow(task(1, "a", .todo)).state, .todo)
    XCTAssertEqual(try taskRow(task(1, "a", .inProgress)).state, .inProgress)
    XCTAssertEqual(
      try taskRow(task(1, "a", .inProgress) { $0.wait = .waiting(waiting) }).state, .waiting)
    XCTAssertEqual(try taskRow(task(1, "a", .todo) { $0.wait = .waiting(waiting) }).state, .waiting)
    XCTAssertEqual(try taskRow(task(1, "a", .done)).state, .done)
  }

  func testWaitingBadgeCountsCalendarDaysSinceTheStartInTheGivenCalendar() throws {
    let lateLastNight = calendar.date(
      from: DateComponents(year: 2025, month: 10, day: 3, hour: 23, minute: 59))!
    let earlyThisMorning = calendar.date(from: DateComponents(year: 2025, month: 10, day: 4))!
    let row = { (since: Date) in
      try self.taskRow(
        self.task(1) { $0.wait = .waiting(TaskItem.Waiting(reason: "経理の返事", since: since)) })
    }

    XCTAssertEqual(
      try row(lateLastNight).waiting, .init(reason: "経理の返事", days: 1), "日付をまたげば数分前でも 1 日")
    XCTAssertEqual(try row(earlyThisMorning).waiting?.days, 0, "今日始まった待ちは 0 日")
  }

  func testWorkspaceIsTheNameOrNoneForAnUnresolvableReference() throws {
    XCTAssertEqual(try taskRow(task(1) { $0.workspace = self.opened.id }).workspace, "orbe")
    XCTAssertEqual(try taskRow(task(1) { $0.workspace = self.other.id }).workspace, "web-app")
    XCTAssertNil(try taskRow(task(1)).workspace)
    XCTAssertNil(try taskRow(task(1) { $0.workspace = UUID() }).workspace, "削除された workspace は「なし」")
  }
}
