import XCTest

@testable import Orbe

/// 待ちの条件の不変条件（待っている間だけ持つ・付け直すと経過が空から始まる・理由だけを変えても残る）と、確認の結果の
/// 書き戻し（成功か期限で 1 回の変異で「解けた」に置き換わる・同一性の合わない古い結果は捨てる）、保存と読み戻し。
///
/// 壊れると何が起きるか: 外した・付け直した条件の古い結果が新しい条件の記録に混ざる、または解いてしまう。期限の過ぎた
/// 条件や秒単位の間隔が入り、裏でコマンドを叩き続ける。完了にしたタスクに起きたことが残り、行に古い出来事が出続ける。
/// 再起動で条件や経過を失い、確認の回数が巻き戻る。
extension TaskStoreTests {
  private func request(
    _ description: String = "PR #214 にレビューが付いたら", command: String = "gh pr view 214",
    minutes: Int = 10, deadline: Date = Date().addingTimeInterval(3 * 86400)
  ) -> WaitConditionRequest {
    WaitConditionRequest(
      description: description, command: command, everyMinutes: minutes, deadline: deadline)
  }

  private func waitingTask(_ store: TaskStore) throws -> (TaskItem, WaitCondition) {
    let task = try store.addWaiting(
      draft("設定の検索を速くする") { $0.waitingReason = "レビュー待ち" }, request())
    return (task, try XCTUnwrap(task.waiting?.condition))
  }

  private func run(_ ending: BackgroundEnding, stdout: String = "", stderr: String = "")
    -> BackgroundRunResult
  {
    let at = Date()
    return BackgroundRunResult(
      commandLine: "gh", startedAt: at, endedAt: at, ending: ending,
      output: .command(
        stdout: .init(data: Data(stdout.utf8)), stderr: .init(data: Data(stderr.utf8))))
  }

  private func conditionUpdate(_ condition: ClearableValue<WaitConditionRequest>) -> TaskUpdate {
    var update = TaskUpdate()
    update.waitingCondition = condition
    return update
  }

  // MARK: - 付ける

  func testConditionIsAddedWithTheWaitAndStartsWithNoChecks() throws {
    let store = TaskStore()

    let (_, condition) = try waitingTask(store)

    XCTAssertEqual(condition.description, "PR #214 にレビューが付いたら")
    XCTAssertEqual(condition.checks, 0)
    XCTAssertEqual(condition.log, [])
  }

  func testConditionNeedsAWaitingTaskThatIsNotDone() throws {
    let store = TaskStore()
    let plain = try store.add(draft("a"))
    let done = try store.add(draft("b") { $0.status = .done })

    assertInvalid({ _ = try store.update(plain.id, self.conditionUpdate(.set(self.request()))) })
    assertInvalid({ _ = try store.update(done.id, self.conditionUpdate(.set(self.request()))) })
    let waiting = try store.add(draft("d") { $0.waitingReason = "返事" })
    var doneWithCondition = conditionUpdate(.set(request()))
    doneWithCondition.status = .done
    XCTAssertThrowsError(try store.update(waiting.id, doneWithCondition)) {
      XCTAssertEqual(
        $0 as? TaskStoreError, .invalid("a done task cannot have a waiting condition"),
        "理由は「完了と同時」（「待っていない」ではない）")
    }
    XCTAssertEqual(
      store.tasks.first { $0.id == waiting.id }, waiting, "拒否された変更はタスクを変えない")
  }

  func testConditionValuesAreValidated() throws {
    let store = TaskStore()
    let (task, _) = try waitingTask(store)

    for bad in [
      request(deadline: Date().addingTimeInterval(-60)), request(minutes: 0),
      request(command: "  "), request("2 行\nの説明"), request(" "),
    ] {
      assertInvalid({ _ = try store.update(task.id, self.conditionUpdate(.set(bad))) })
    }
    var relative = request()
    relative.directory = "src"
    assertInvalid({ _ = try store.update(task.id, self.conditionUpdate(.set(relative))) })
  }

  func testReasonChangeKeepsConditionAndResetGivesANewIdentity() throws {
    let store = TaskStore()
    let (task, condition) = try waitingTask(store)
    store.recordCheck(task.id, condition: condition.id, run(.exited(1)))

    let renamed = try store.update(task.id, TaskUpdate(waitingReason: .set("@sato のレビュー")))
    XCTAssertEqual(renamed.waiting?.condition?.id, condition.id, "理由だけを変えても条件は変わらない")
    XCTAssertEqual(renamed.waiting?.condition?.checks, 1, "経過も残る")

    let reset = try store.update(task.id, conditionUpdate(.set(request("別の条件"))))
    XCTAssertNotEqual(reset.waiting?.condition?.id, condition.id, "付け直すと新しい同一性")
    XCTAssertEqual(reset.waiting?.condition?.checks, 0, "経過は空から始まる")
  }

  func testClearingTheConditionKeepsTheWaitAndClearingTheReasonDropsBoth() throws {
    let store = TaskStore()
    let (task, _) = try waitingTask(store)

    let cleared = try store.update(task.id, conditionUpdate(.clear))
    XCTAssertEqual(cleared.waiting?.reason, "レビュー待ち")
    XCTAssertNil(cleared.waiting?.condition)

    _ = try store.update(task.id, conditionUpdate(.set(request())))
    XCTAssertNil(try store.update(task.id, TaskUpdate(waitingReason: .clear)).wait)
  }

  // MARK: - 確かめる・解ける

  func testFailedCheckIsRecordedAndTheWaitContinues() throws {
    let store = TaskStore()
    let (task, condition) = try waitingTask(store)

    let resolution = store.recordCheck(
      task.id, condition: condition.id, run(.exited(1), stderr: "command not found"))

    XCTAssertNil(resolution)
    let recorded = try XCTUnwrap(store.tasks.first?.waiting?.condition)
    XCTAssertEqual(recorded.checks, 1)
    XCTAssertEqual(recorded.log.last?.result, .exited(1))
    XCTAssertEqual(recorded.log.last?.stderr, "command not found")
  }

  func testSuccessfulCheckResolvesTheWaitInOneMutation() throws {
    let store = TaskStore()
    let (task, condition) = try waitingTask(store)
    store.recordCheck(task.id, condition: condition.id, run(.exited(1)))

    let resolution = try XCTUnwrap(
      store.recordCheck(
        task.id, condition: condition.id,
        run(.exited(0), stdout: "レビューが付いた\n@sato · CHANGES_REQUESTED\n")))

    XCTAssertEqual(store.tasks.first?.waitResolution, resolution)
    XCTAssertNil(store.tasks.first?.waiting, "待ちは外れる")
    XCTAssertEqual(resolution.headline, "レビューが付いた", "行に出すのは標準出力の 1 行目")
    XCTAssertEqual(resolution.restOfOutput, ["@sato · CHANGES_REQUESTED"])
    XCTAssertEqual(resolution.waiting.reason, "レビュー待ち")
    XCTAssertEqual(resolution.waiting.condition?.checks, 2, "解けた回も確認の回数に入る")
    XCTAssertEqual(store.tasks.first?.status, task.status, "ステータスは変わらない")
  }

  func testOnlyExitCodeZeroResolves() throws {
    let store = TaskStore()
    let (task, condition) = try waitingTask(store)

    for ending in [
      BackgroundEnding.exited(2), .signaled(15), .limited(.output), .stopped,
      .notStarted(.directoryMissing("/gone")),
    ] {
      XCTAssertNil(store.recordCheck(task.id, condition: condition.id, run(ending)))
    }
    XCTAssertEqual(store.tasks.first?.waiting?.condition?.checks, 5)
  }

  func testStaleResultForAReplacedConditionIsDropped() throws {
    let store = TaskStore()
    let (task, old) = try waitingTask(store)
    _ = try store.update(task.id, conditionUpdate(.set(request("別の条件"))))

    XCTAssertNil(store.recordCheck(task.id, condition: old.id, run(.exited(0))))
    XCTAssertNil(store.expire(task.id, condition: old.id))

    let current = try XCTUnwrap(store.tasks.first?.waiting?.condition)
    XCTAssertEqual(current.checks, 0, "古い条件の結果は新しい条件に混ざらない")
  }

  func testLogKeepsOnlyTheRecentRecordsButCountsEveryCheck() throws {
    let store = TaskStore()
    let (task, condition) = try waitingTask(store)

    for _ in 0..<(WaitCondition.logLimit + 3) {
      store.recordCheck(task.id, condition: condition.id, run(.exited(1)))
    }

    let recorded = try XCTUnwrap(store.tasks.first?.waiting?.condition)
    XCTAssertEqual(recorded.log.count, WaitCondition.logLimit)
    XCTAssertEqual(recorded.checks, WaitCondition.logLimit + 3)
  }

  func testExpiryResolvesAtTheDeadline() throws {
    let store = TaskStore()
    let (task, condition) = try waitingTask(store)

    let resolution = try XCTUnwrap(store.expire(task.id, condition: condition.id))

    XCTAssertEqual(resolution.how, .expired)
    XCTAssertEqual(resolution.at, condition.deadline)
    XCTAssertNil(resolution.headline, "期限の起きたことは「期限が来た」で出す")
  }

  // MARK: - 起きたことが消える

  func testResolutionIsClearedByANewWaitByDoneAndByDelivery() throws {
    let store = TaskStore()
    func resolved() throws -> Int {
      let (task, condition) = try waitingTask(store)
      store.recordCheck(task.id, condition: condition.id, run(.exited(0)))
      return task.id
    }

    let byNoWaitChange = try resolved()
    XCTAssertNotNil(
      try store.update(byNoWaitChange, TaskUpdate(waitingReason: .clear)).waitResolution,
      "待ちを外す変更では消えない")

    let byNewWait = try resolved()
    let rewaited = try store.update(byNewWait, TaskUpdate(waitingReason: .set("次の返事")))
    XCTAssertEqual(rewaited.waiting?.reason, "次の返事")
    XCTAssertNil(rewaited.waitResolution, "新しい待ちを付けると消える")

    let byDone = try resolved()
    XCTAssertNil(try store.update(byDone, TaskUpdate(status: .done)).wait, "完了にすると消える")

    let byDelivery = try resolved()
    store.clearResolution(byDelivery)
    XCTAssertNil(store.tasks.first { $0.id == byDelivery }?.wait, "会話へ届けると消える")
  }

  // MARK: - 保存

  /// 記録はどの結果でも読み戻せる（1 件でも読めなければ、タスク一覧ごと退避される）。
  func testConditionProgressAndResolutionSurviveRelaunch() throws {
    let store = TaskStore()
    let (waiting, condition) = try waitingTask(store)
    for ending in [
      BackgroundEnding.exited(1), .signaled(15), .stopped, .notStarted(.directoryMissing("/gone")),
    ] + BackgroundProcess.Limit.allCases.map(BackgroundEnding.limited) {
      store.recordCheck(waiting.id, condition: condition.id, run(ending, stdout: "まだ"))
    }
    let (resolved, other) = try waitingTask(store)
    store.recordCheck(resolved.id, condition: other.id, run(.exited(0), stdout: "付いた"))
    let (expired, third) = try waitingTask(store)
    store.expire(expired.id, condition: third.id)

    XCTAssertEqual(relaunched().tasks, store.tasks)
  }
}
