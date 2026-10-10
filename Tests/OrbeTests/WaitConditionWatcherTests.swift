import XCTest

@testable import Orbe

/// 待ちの条件の係——付けた直後に 1 回確かめ、以後は間隔ごと。成功か期限で待ちが解け、以後は走らない。付け直し・解除は
/// 走っている回を止め、競って届いた古い結果を新しい条件に混ぜない。Orbe を終了したまま期限を過ぎた条件は、起動で解ける。
/// 解けたときだけ、解けたタスクと起きたことを知らせる。
///
/// 壊れると何が起きるか: コマンドの書き間違いが間隔の分だけ見えない。解けた・外した条件のコマンドが裏で走り続ける。
/// 付け直した条件が、前の条件の成功で解けてしまう。終了している間に過ぎた期限が、いつまでも解けない。解けても
/// 知らせが届かない、または確かめるたびに知らせが鳴る。
final class WaitConditionWatcherTests: OrbeTestCase {
  private var now = Date()
  private var armed: (date: Date, fire: () -> Void)?
  private var runner: WatcherFakeRunner!
  private var scheduler: BackgroundScheduler!
  private var watcher: WaitConditionWatcher?
  private var resolved: [(task: Int, resolution: WaitResolution)] = []

  override func setUp() {
    now = Date()
    runner = WatcherFakeRunner()
    scheduler = BackgroundScheduler(run: runner.run)
    scheduler.now = { [unowned self] in now }
    scheduler.arm = { [unowned self] date, fire in
      armed = (date, fire)
      return { [unowned self] in armed = nil }
    }
  }

  override func tearDown() {
    watcher = nil
    scheduler = nil
  }

  private func start(_ store: TaskStore) {
    let watcher = WaitConditionWatcher(store: store, scheduler: scheduler) { [unowned self] in
      resolved.append(($0, $1))
    }
    watcher.start()
    self.watcher = watcher
  }

  /// 係の書き戻しと登録し直しは次の main の回へ送られるので、それを流す。
  private func settle() {
    for _ in 0..<3 {
      let turn = expectation(description: "main")
      DispatchQueue.main.async { turn.fulfill() }
      wait(for: [turn], timeout: 1)
    }
  }

  private func request(_ description: String = "レビューが付いたら", deadlineIn: TimeInterval = 3600)
    -> WaitConditionRequest
  {
    WaitConditionRequest(
      description: description, command: "gh pr view 214", everyMinutes: 10,
      deadline: Date().addingTimeInterval(deadlineIn))
  }

  private func addWaiting(_ store: TaskStore) throws -> TaskItem {
    var draft = TaskDraft(title: "設定の検索を速くする")
    draft.waitingReason = "レビュー待ち"
    draft.waitingCondition = request()
    return try store.add(draft)
  }

  private func result(_ code: Int32, stdout: String = "") -> BackgroundRunResult {
    BackgroundRunResult(
      commandLine: "gh pr view 214", startedAt: now, endedAt: now, ending: .exited(code),
      output: .command(stdout: .init(data: Data(stdout.utf8)), stderr: .init()))
  }

  func testNewConditionIsCheckedRightAwayThenEveryInterval() throws {
    let store = TaskStore()
    let task = try addWaiting(store)
    start(store)

    XCTAssertEqual(runner.calls.count, 1, "付けた直後に 1 回確かめる")
    XCTAssertEqual(
      runner.calls.first?.job,
      .command(BackgroundCommand(script: "gh pr view 214", directory: nil)))

    runner.finish(0, with: result(1))
    settle()

    XCTAssertEqual(store.tasks.first { $0.id == task.id }?.waiting?.condition?.checks, 1)
    XCTAssertEqual(armed?.date, now.addingTimeInterval(600), "次は確かめた時刻から間隔の後")
    XCTAssertTrue(resolved.isEmpty, "解けていない確認は知らせない")
  }

  func testSuccessResolvesTheWaitAndStopsChecking() throws {
    let store = TaskStore()
    let task = try addWaiting(store)
    start(store)

    runner.finish(0, with: result(0, stdout: "レビューが付いた"))
    settle()
    now = now.addingTimeInterval(3600)
    scheduler.recount()

    XCTAssertEqual(store.tasks.first { $0.id == task.id }?.waitResolution?.headline, "レビューが付いた")
    XCTAssertEqual(runner.calls.count, 1, "解けた条件はもう走らない")
    XCTAssertEqual(resolved.map(\.task), [task.id])
    XCTAssertEqual(resolved.first?.resolution.headline, "レビューが付いた")
  }

  /// 付け直しは走っている回を止め、付け直しの後に届いた前の条件の成功は新しい条件を解かない。
  func testReplacedConditionStopsTheRunAndIgnoresTheOldResult() throws {
    let store = TaskStore()
    let task = try addWaiting(store)
    start(store)

    runner.finish(0, with: result(0, stdout: "前の条件"))
    var update = TaskUpdate()
    update.waitingCondition = .set(request("別の条件"))
    _ = try store.update(task.id, update)
    settle()

    let current = try XCTUnwrap(store.tasks.first { $0.id == task.id }?.waiting?.condition)
    XCTAssertEqual(current.description, "別の条件")
    XCTAssertEqual(current.checks, 0, "前の条件の結果は混ざらない")
    XCTAssertEqual(runner.calls.count, 2, "新しい条件も付けた直後に確かめる")
  }

  func testClearedConditionStopsTheRunningCheck() throws {
    let store = TaskStore()
    let task = try addWaiting(store)
    start(store)

    var update = TaskUpdate()
    update.waitingCondition = .clear
    _ = try store.update(task.id, update)
    settle()
    now = now.addingTimeInterval(3600)
    scheduler.recount()

    XCTAssertEqual(runner.stopped, [0], "走っている回を止める")
    XCTAssertEqual(runner.calls.count, 1, "外した条件はもう走らない")
    XCTAssertEqual(store.tasks.first { $0.id == task.id }?.waiting?.reason, "レビュー待ち")
  }

  /// 終了している間に期限を過ぎた条件は、起動したときに「期限が来た」で解ける。
  func testConditionPastItsDeadlineResolvesOnStart() throws {
    let task = try addWaiting(TaskStore())
    let condition = try XCTUnwrap(task.waiting?.condition)
    now = condition.deadline.addingTimeInterval(86400)

    let relaunched = TaskStore()
    start(relaunched)
    settle()

    let resolution = try XCTUnwrap(relaunched.tasks.first { $0.id == task.id }?.waitResolution)
    XCTAssertEqual(resolution.how, .expired)
    XCTAssertEqual(resolution.at, condition.deadline)
    XCTAssertEqual(runner.calls.count, 0, "期限を過ぎた条件は確かめずに解ける")
    XCTAssertEqual(resolved.map(\.task), [task.id], "起動直後に解けたものも知らせる")
    XCTAssertEqual(resolved.first?.resolution.how, .expired)
  }
}

private final class WatcherFakeRunner {
  private(set) var calls: [(job: BackgroundJob, completion: (BackgroundRunResult) -> Void)] = []
  private(set) var stopped: [Int] = []

  func run(_ job: BackgroundJob, completion: @escaping (BackgroundRunResult) -> Void)
    -> BackgroundRunHandle
  {
    let index = calls.count
    calls.append((job, completion))
    return BackgroundRunHandle { [unowned self] in stopped.append(index) }
  }

  func finish(_ index: Int, with result: BackgroundRunResult) {
    calls[index].completion(result)
  }
}
