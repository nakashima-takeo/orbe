import XCTest

@testable import Orbe

/// タスク画面（⌘⇧X）の一覧の行を、タスクの列・入力・範囲から組む純関数 `TaskPaletteRows` を固定する。
///
/// 壊れると何が起きるか: 人と agent が決めた列の順が画面で組み替わり、`orb task list` と画面の並びが
/// 食い違う。絞り込みや範囲の外のタスクが混ざる、または消える。待ちの日数・期限・workspace の札が
/// 別の値を言い、人が「今日やるもの」「自分の workspace のもの」を見誤る。ヘッダーの件数が打った文字で
/// 揺れて、残りの量が分からなくなる。
@MainActor
final class TaskPaletteRowsTests: OrbeTestCase {
  private let calendar = DesignSceneFixtures.taskCalendar
  private let opened = TaskPaletteWorkspaces.Entry(id: UUID(), name: "orbe")
  private let other = TaskPaletteWorkspaces.Entry(id: UUID(), name: "web-app")
  private var workspaces: TaskPaletteWorkspaces {
    TaskPaletteWorkspaces(opened: opened, all: [opened, other])
  }
  private let today = TaskItem.DueDate(year: 2025, month: 10, day: 4)!
  private var now: Date {
    calendar.date(from: DateComponents(year: 2025, month: 10, day: 4, hour: 10))!
  }

  private func task(
    _ id: Int, _ title: String = "タスク", _ status: TaskItem.Status = .todo, by: String? = nil,
    _ mutate: (inout TaskItem) -> Void = { _ in }
  ) -> TaskItem {
    var item = TaskItem(
      id: id, title: title, status: status, waiting: nil, priority: .medium, due: nil,
      workspace: nil, memo: "", createdAt: now, createdBy: by)
    mutate(&item)
    return item
  }

  private func input(
    _ tasks: [TaskItem], query: String = "", scope: TaskPaletteScope = .all,
    doneExpanded: Bool = false
  ) -> TaskPaletteRows.Input {
    TaskPaletteRows.Input(
      tasks: tasks, query: query, scope: scope, doneExpanded: doneExpanded,
      workspaces: workspaces, today: today, timeZone: calendar.timeZone, items: [:],
      viewerLogin: nil)
  }

  private func taskIDs(_ rows: [TaskPaletteRow]) -> [Int] {
    rows.compactMap { if case .task(let row) = $0 { row.id } else { nil } }
  }

  private func taskRow(_ item: TaskItem) throws -> TaskPaletteTaskRow {
    let rows = TaskPaletteRows.build(input([item], doneExpanded: true))
    return try XCTUnwrap(
      rows.lazy.compactMap { if case .task(let row) = $0 { row } else { nil } }.first)
  }

  // MARK: - 欄と並び

  func testRowsAreGroupedInProgressThenTodoThenDoneHeaderKeepingTheListOrderWithinEachSection() {
    let tasks = [
      task(1, "a", .todo), task(2, "b", .inProgress), task(3, "c", .done), task(4, "d", .todo),
      task(5, "e", .inProgress),
    ]

    let rows = TaskPaletteRows.build(input(tasks))

    XCTAssertEqual(rows.count, 7)
    XCTAssertEqual(rows[0], .sectionHeader(.inProgress, count: 2))
    XCTAssertEqual(rows[3], .sectionHeader(.todo, count: 2))
    XCTAssertEqual(rows[6], .doneHeader(count: 1, expanded: false), "完了は最初は畳まれ、見出しだけが出る")
    XCTAssertEqual(taskIDs(rows), [2, 5, 1, 4], "どの欄でも列の順のまま")
  }

  func testExpandedDoneSectionListsDoneTasksUnderTheHeaderInListOrder() {
    let tasks = [task(1, "a", .done), task(2, "b", .todo), task(3, "c", .done)]

    let rows = TaskPaletteRows.build(input(tasks, doneExpanded: true))

    XCTAssertEqual(rows[2], .doneHeader(count: 2, expanded: true))
    XCTAssertEqual(taskIDs(rows), [2, 1, 3])
  }

  func testEmptySectionsAreOmittedWithTheirHeaders() {
    let rows = TaskPaletteRows.build(input([task(1, "a", .todo)]))

    XCTAssertEqual(rows.count, 2, "進行中と完了の欄は見出しごと出ない")
    XCTAssertEqual(rows[0], .sectionHeader(.todo, count: 1))
  }

  func testNoTasksAndNoQueryShowsTheEmptyInfoRowOnly() {
    XCTAssertEqual(TaskPaletteRows.build(input([])), [.empty])
  }

  // MARK: - 入力・追加の行

  func testQueryPutsTheTrimmedAddRowFirstAndFiltersTitlesIgnoringCase() {
    let tasks = [
      task(1, "PR の説明を書く"), task(2, "経費精算を出す"), task(3, "pr をレビューする", .done),
    ]

    let rows = TaskPaletteRows.build(input(tasks, query: "  Pr  ", doneExpanded: true))

    XCTAssertEqual(rows.first, .add(title: "Pr"), "追加の行は前後の空白を除いたタイトルで先頭に出る")
    XCTAssertEqual(taskIDs(rows), [1, 3], "大文字小文字を区別せず部分一致で絞る")
    XCTAssertTrue(rows.contains(.doneHeader(count: 1, expanded: true)), "完了の件数も絞った数")
  }

  func testWhitespaceOnlyQueryNeitherAddsNorFilters() {
    let rows = TaskPaletteRows.build(input([task(1, "a"), task(2, "b")], query: "   "))

    XCTAssertFalse(rows.contains(.add(title: "")))
    XCTAssertEqual(taskIDs(rows), [1, 2])
  }

  func testQueryMatchingNothingShowsOnlyTheAddRow() {
    let rows = TaskPaletteRows.build(input([task(1, "経費精算を出す")], query: "歯医者"))

    XCTAssertEqual(rows, [.add(title: "歯医者")])
  }

  // MARK: - 範囲と件数

  func testOpenedScopeShowsOnlyTasksOfTheOpenedWorkspace() {
    let tasks = [
      task(1) { $0.workspace = self.opened.id }, task(2) { $0.workspace = self.other.id },
      task(3),
    ]

    let rows = TaskPaletteRows.build(input(tasks, scope: .opened))

    XCTAssertEqual(taskIDs(rows), [1])
  }

  func testOpenedScopeWithNoTasksThereShowsTheEmptyInfoRow() {
    let rows = TaskPaletteRows.build(input([task(1)], scope: .opened))

    XCTAssertEqual(rows, [.empty])
  }

  func testCountsAreUndoneTasksPerScopeAndIgnoreTheQuery() {
    let tasks = [
      task(1, "a", .todo) { $0.workspace = self.opened.id },
      task(2, "b", .inProgress) { $0.workspace = self.opened.id },
      task(3, "c", .done) { $0.workspace = self.opened.id },
      task(4, "d", .todo) { $0.workspace = self.other.id },
      task(5, "e", .todo),
    ]

    let all = TaskPaletteRows.counts(input(tasks, query: "a", scope: .all))
    let scoped = TaskPaletteRows.counts(input(tasks, query: "a", scope: .opened))

    XCTAssertEqual(all, TaskPaletteCounts(scoped: 4, all: 4, opened: 2))
    XCTAssertEqual(scoped, TaskPaletteCounts(scoped: 2, all: 4, opened: 2))
  }

  // MARK: - タスクの行の札

  func testGlyphShowsDoneOverWaitingAndWaitingOverInProgressOrTodo() throws {
    let waiting = TaskItem.Waiting(reason: "返事", since: now)

    XCTAssertEqual(try taskRow(task(1, "a", .todo)).glyph, .todo)
    XCTAssertEqual(try taskRow(task(1, "a", .inProgress)).glyph, .inProgress)
    XCTAssertEqual(try taskRow(task(1, "a", .inProgress) { $0.waiting = waiting }).glyph, .waiting)
    XCTAssertEqual(try taskRow(task(1, "a", .todo) { $0.waiting = waiting }).glyph, .waiting)
    XCTAssertEqual(try taskRow(task(1, "a", .done)).glyph, .done)
    XCTAssertTrue(try taskRow(task(1, "a", .done)).isDone)
  }

  func testPriorityBadgeIsShownOnlyForHighAndLow() throws {
    XCTAssertEqual(try taskRow(task(1) { $0.priority = .high }).priority, .high)
    XCTAssertEqual(try taskRow(task(1) { $0.priority = .low }).priority, .low)
    XCTAssertNil(try taskRow(task(1) { $0.priority = .medium }).priority)
  }

  func testWaitingBadgeCountsCalendarDaysSinceTheStartInTheGivenCalendar() throws {
    let lateLastNight = calendar.date(
      from: DateComponents(year: 2025, month: 10, day: 3, hour: 23, minute: 59))!
    let earlyThisMorning = calendar.date(from: DateComponents(year: 2025, month: 10, day: 4))!
    let row = { (since: Date) in
      try self.taskRow(
        self.task(1) { $0.waiting = TaskItem.Waiting(reason: "経理の返事", since: since) })
    }

    XCTAssertEqual(
      try row(lateLastNight).waiting, .init(reason: "経理の返事", days: 1), "日付をまたげば数分前でも 1 日")
    XCTAssertEqual(try row(earlyThisMorning).waiting?.days, 0, "今日始まった待ちは 0 日")
  }

  func testDueAndCreatorBadgesComeFromTheTask() throws {
    let due = TaskItem.DueDate(year: 2025, month: 10, day: 6)!
    let row = try taskRow(task(1, by: "claude") { $0.due = due })

    XCTAssertEqual(row.due, .init(date: due, today: today))
    XCTAssertEqual(row.createdBy, "claude")
  }

  func testWorkspaceBadgeIsOpenedOtherOrNoneForAnUnresolvableReference() throws {
    XCTAssertEqual(
      try taskRow(task(1) { $0.workspace = self.opened.id }).workspace, .opened("orbe"))
    XCTAssertEqual(
      try taskRow(task(1) { $0.workspace = self.other.id }).workspace, .other("web-app"))
    XCTAssertNil(try taskRow(task(1)).workspace)
    XCTAssertNil(try taskRow(task(1) { $0.workspace = UUID() }).workspace, "削除された workspace は「なし」")
  }
}
