import XCTest

@testable import Orbe

/// 右の欄（→ で入る）の項目の移動・選択式の値・文字の項目の編集と、その確定・取り消し。
extension TaskPaletteModelTests {
  /// 未着手 2 件（a・b）を開き、a の右の欄に入った状態。
  func detailOfFirst(_ tasks: [TaskItem]? = nil) -> TaskPaletteModel {
    let palette = model(tasks ?? [task(1, "a"), task(2, "b")])
    palette.enterDetail()
    XCTAssertEqual(palette.selectedTask?.id, 1, "前提: a の右の欄")
    return palette
  }

  /// 完了のタスク 1 件だけを開き、完了の欄を開いてその右の欄に入った状態。
  func detailOfDone() -> TaskPaletteModel {
    let palette = model([task(1, "a", .done)])
    palette.toggleDoneExpanded()
    palette.jump(1)
    palette.enterDetail()
    XCTAssertEqual(palette.selectedTask?.status, .done, "前提: 完了のタスクの右の欄")
    return palette
  }

  func edit(_ palette: TaskPaletteModel, _ field: TaskDetailField, _ text: String) {
    palette.area = .detail(.field(field))
    palette.beginEditing()
    palette.draftText = text
  }

  // MARK: - 入る・出る・項目の移動

  func testEnteringDetailNeedsATaskRowAndStartsAtStatus() {
    let palette = model([task(1, "a"), task(2, "b", .done)])
    palette.query = "a"
    palette.enterDetail()
    XCTAssertEqual(palette.area, .list, "追加の行では入らない")

    palette.query = ""
    palette.enterDetail()
    XCTAssertEqual(palette.area, .detail(.field(.status)))
    XCTAssertEqual(palette.selectedTask?.id, 1)
  }

  func testFieldMovementStopsAtTheEnds() {
    let palette = detailOfFirst()

    palette.moveField(-1)
    palette.moveField(-1)
    XCTAssertEqual(palette.area, .detail(.field(.title)))

    for _ in 0..<10 { palette.moveField(1) }
    XCTAssertEqual(palette.area, .detail(.field(.description)))
  }

  // MARK: - 選択式の値

  func testStatusChoiceMovesBetweenTodoAndInProgressAndStopsAtTheEnds() throws {
    let palette = detailOfFirst()

    palette.changeValue(1)
    XCTAssertEqual(try storedTask(palette, 1).status, .inProgress)
    palette.changeValue(1)
    XCTAssertEqual(try storedTask(palette, 1).status, .inProgress)
    palette.changeValue(-1)
    XCTAssertEqual(try storedTask(palette, 1).status, .todo)
    XCTAssertEqual(palette.area, .detail(.field(.status)), "値を変えても右の欄に居続ける")
    XCTAssertEqual(palette.selectedTask?.id, 1)
  }

  func testStatusChoiceOnADoneTaskReturnsItToTheChosenEnd() throws {
    let toLeft = detailOfDone()
    toLeft.changeValue(-1)
    XCTAssertEqual(try storedTask(toLeft, 1).status, .todo)

    let toRight = detailOfDone()
    toRight.changeValue(1)
    XCTAssertEqual(try storedTask(toRight, 1).status, .inProgress)
  }

  func testPriorityChoiceStepsHighMediumLowAndStopsAtTheEnds() throws {
    let palette = detailOfFirst()
    palette.area = .detail(.field(.priority))

    palette.changeValue(-1)
    palette.changeValue(-1)
    XCTAssertEqual(try storedTask(palette, 1).priority, .high)
    palette.changeValue(1)
    palette.changeValue(1)
    palette.changeValue(1)
    XCTAssertEqual(try storedTask(palette, 1).priority, .low)
  }

  func testWorkspaceChoiceCyclesNoneThenTheSidebarOrder() throws {
    let palette = detailOfFirst()
    palette.area = .detail(.field(.workspace))

    palette.changeValue(1)
    XCTAssertEqual(try storedTask(palette, 1).workspace, openedWorkspace.id)
    palette.changeValue(1)
    XCTAssertEqual(try storedTask(palette, 1).workspace, otherWorkspace.id)
    palette.changeValue(1)
    XCTAssertNil(try storedTask(palette, 1).workspace, "末尾の次は「なし」へ回る")
    palette.changeValue(-1)
    XCTAssertEqual(try storedTask(palette, 1).workspace, otherWorkspace.id)
  }

  /// 削除された workspace を指すタスクは「なし」として扱い、そこから巡回する。
  func testWorkspaceChoiceFromAnUnresolvableReferenceStartsFromNone() throws {
    let palette = detailOfFirst([task(1, "a") { $0.workspace = UUID() }])
    palette.area = .detail(.field(.workspace))

    palette.changeValue(1)

    XCTAssertEqual(try storedTask(palette, 1).workspace, openedWorkspace.id)
  }

  // MARK: - 文字の項目の編集

  func testTitleEditCommitsTheTrimmedTitleAndAnEmptyTitleCancels() throws {
    let palette = detailOfFirst()

    edit(palette, .title, "  新しい名前 ")
    XCTAssertTrue(palette.endEditing(commit: true))
    XCTAssertEqual(try storedTask(palette, 1).title, "新しい名前")

    edit(palette, .title, "   ")
    XCTAssertTrue(palette.endEditing(commit: true))
    XCTAssertEqual(try storedTask(palette, 1).title, "新しい名前", "空で確定は取り消し")
    XCTAssertNil(palette.draft)
    XCTAssertNil(palette.error)
  }

  func testTitleTheStoreRejectsShowsTheTitleErrorAndKeepsEditing() throws {
    let palette = detailOfFirst()
    edit(palette, .title, "改行\u{2028}入り")

    XCTAssertFalse(palette.endEditing(commit: true))

    XCTAssertEqual(palette.error, .title)
    XCTAssertEqual(palette.draft?.text, "改行\u{2028}入り", "打った内容のまま編集を続ける")
    XCTAssertEqual(try storedTask(palette, 1).title, "a")
  }

  func testWaitingReasonIsSetByCommitAndClearedByAnEmptyCommit() throws {
    let palette = detailOfFirst()

    edit(palette, .waiting, "経理の返事")
    palette.endEditing(commit: true)
    XCTAssertEqual(try storedTask(palette, 1).waiting?.reason, "経理の返事")

    edit(palette, .waiting, "")
    palette.endEditing(commit: true)
    XCTAssertNil(try storedTask(palette, 1).waiting)
  }

  /// 完了したタスクの待ちは編集できない（フッターもその ↵ を案内しない）。他の文字の項目は編集できる。
  func testWaitingCannotBeEditedOnADoneTask() {
    let palette = detailOfDone()
    palette.area = .detail(.field(.waiting))
    XCTAssertFalse(palette.canEdit(.waiting))
    XCTAssertTrue(palette.canEdit(.title))

    palette.beginEditing()

    XCTAssertNil(palette.draft)
  }

  func testDueAcceptsMonthDayAndClearsOnAnEmptyCommit() throws {
    let palette = detailOfFirst()

    edit(palette, .due, "10/9")
    palette.endEditing(commit: true)
    XCTAssertEqual(try storedTask(palette, 1).due, TaskItem.DueDate("2025-10-09"))

    edit(palette, .due, "")
    palette.endEditing(commit: true)
    XCTAssertNil(try storedTask(palette, 1).due)
  }

  func testUnreadableDueShowsTheDueErrorAndKeepsEditing() throws {
    let palette = detailOfFirst()
    edit(palette, .due, "あした")

    XCTAssertFalse(palette.endEditing(commit: true))

    XCTAssertEqual(palette.error, .due)
    XCTAssertEqual(palette.draft?.field, .due)
    XCTAssertNil(try storedTask(palette, 1).due)
  }

  func testDescriptionKeepsLinesAndSurroundingWhitespaceAsTyped() throws {
    let palette = detailOfFirst()
    edit(palette, .description, "1 行目\n  2 行目\n")

    palette.endEditing(commit: true)

    XCTAssertEqual(try storedTask(palette, 1).description, "1 行目\n  2 行目\n")
  }

  /// 1 行の項目の esc は、打った内容を取り消して項目に居たまま編集を終える。
  func testEscapeDiscardsTheEditAndStaysOnTheField() throws {
    let palette = detailOfFirst()
    edit(palette, .waiting, "書きかけ")

    palette.endEditing(commit: false)

    XCTAssertNil(try storedTask(palette, 1).waiting)
    XCTAssertNil(palette.draft)
    XCTAssertEqual(palette.area, .detail(.field(.waiting)))
  }

  // MARK: - 別の操作で編集を抜けると確定する

  func testClickingAnotherRowCommitsTheEditToTheTaskBeingEdited() throws {
    let palette = detailOfFirst()
    edit(palette, .description, "残したい詳細")

    palette.tapRow(.task(2))

    XCTAssertEqual(try storedTask(palette, 1).description, "残したい詳細", "編集していたタスクへ書く")
    XCTAssertEqual(try storedTask(palette, 2).description, "")
    XCTAssertNil(palette.draft)
    XCTAssertEqual(palette.area, .list)
    XCTAssertEqual(palette.selectedID, .task(2))
  }

  func testClickingAnotherFieldCommitsTheEditAndStartsEditingThatField() throws {
    let palette = detailOfFirst()
    edit(palette, .title, "直した名前")

    palette.tapField(.description)

    XCTAssertEqual(try storedTask(palette, 1).title, "直した名前")
    XCTAssertEqual(palette.draft?.field, .description)
  }

  func testSwitchingScopeOrTabCommitsTheEdit() throws {
    let palette = detailOfFirst()
    edit(palette, .description, "範囲で抜ける")
    palette.toggleScope()
    XCTAssertEqual(try storedTask(palette, 1).description, "範囲で抜ける")

    palette.toggleScope()
    palette.enterDetail()
    edit(palette, .description, "タブで抜ける")
    palette.toggleTab()
    XCTAssertEqual(try storedTask(palette, 1).description, "タブで抜ける")
  }

  /// 画面を閉じる・別の画面へ差し替わる・アプリの終了は、どれもこの 1 本を通る。
  func testLeavingEditingCommitsWhatWasTyped() throws {
    let palette = detailOfFirst()
    edit(palette, .description, "閉じても残る")

    palette.leaveEditing()

    XCTAssertEqual(try storedTask(palette, 1).description, "閉じても残る")
    XCTAssertEqual(TaskStore().tasks.first?.description, "閉じても残る", "即時に保存される")
  }

  /// 読めない期限のまま別の行をクリックすると、確定できない入力は捨てられる。そのとき理由は
  /// フッターに残る（`leaveEditing` の契約）。
  func testClickingAwayFromAnUnreadableDueLeavesTheReasonInTheFooter() {
    let palette = detailOfFirst()
    edit(palette, .due, "あした")

    palette.tapRow(.task(2))

    XCTAssertNil(palette.draft)
    XCTAssertEqual(palette.error, .due)
  }

  // MARK: - 右の欄での完了・削除と、agent の変更

  func testCompletingAnUnselectedRowFromItsIconKeepsTheDetail() throws {
    let palette = model([task(1, "a"), task(2, "b"), task(3, "c")])
    palette.move(1)
    palette.enterDetail()

    palette.toggleDone(1)

    XCTAssertEqual(palette.area, .detail(.field(.status)), "見ている b の右の欄に居続ける")
    XCTAssertEqual(palette.selectedTask?.id, 2)
  }

  func testCompletingFromDetailReturnsToTheListAtTheSamePosition() throws {
    let palette = detailOfFirst()

    palette.toggleDone(1)

    XCTAssertEqual(try storedTask(palette, 1).status, .done)
    XCTAssertEqual(palette.area, .list)
    XCTAssertEqual(palette.selectedID, .task(2))
  }

  func testTaskDeletedByAgentWhileEditingDiscardsTheDraftAndReturnsToTheList() throws {
    let palette = detailOfFirst()
    edit(palette, .description, "書きかけ")

    try palette.store.delete(1)
    palette.reconcile()

    XCTAssertNil(palette.draft)
    XCTAssertEqual(palette.area, .list)
    XCTAssertEqual(palette.selectedID, .task(2))
    XCTAssertEqual(try storedTask(palette, 2).description, "", "下書きを別のタスクへ書かない")
  }

  /// 項目をクリックして編集を始めただけ（打っていない）なら、離れるときに古い値を書き戻さない。
  func testLeavingAnUntypedEditKeepsWhatTheAgentWroteMeanwhile() throws {
    let palette = detailOfFirst()
    for field in [TaskDetailField.description, .title, .waiting, .due] {
      palette.tapField(field)
      var update = TaskUpdate()
      switch field {
      case .description: update.description = "agent の詳細"
      case .title: update.title = "agent のタイトル"
      case .waiting: update.waitingReason = .set("agent の理由")
      default: update.due = .set(TaskItem.DueDate("2025-10-20")!)
      }
      _ = try palette.store.update(1, update)

      palette.leaveEditing()
    }

    let task = try storedTask(palette, 1)
    XCTAssertEqual(task.description, "agent の詳細")
    XCTAssertEqual(task.title, "agent のタイトル")
    XCTAssertEqual(task.waiting?.reason, "agent の理由")
    XCTAssertEqual(task.due, TaskItem.DueDate("2025-10-20"))
  }

  /// 打った内容は、その間に agent が同じ項目を変えていても後勝ちで書く。
  func testLeavingATypedEditStillOverwritesTheAgent() throws {
    let palette = detailOfFirst()
    palette.tapField(.description)
    palette.draftText = "人が打った詳細"
    var update = TaskUpdate()
    update.description = "agent の詳細"
    _ = try palette.store.update(1, update)

    palette.leaveEditing()

    XCTAssertEqual(try storedTask(palette, 1).description, "人が打った詳細")
  }

  func testAgentChangingAnotherTaskKeepsTheDetailAndTheDraft() throws {
    let palette = detailOfFirst()
    edit(palette, .description, "書きかけ")

    let inserted = try palette.store.add(TaskDraft(title: "agent が足した"))
    try palette.store.move(inserted.id, .before, 1)
    palette.reconcile()

    XCTAssertEqual(palette.selectedTask?.id, 1)
    XCTAssertEqual(palette.draft?.text, "書きかけ")
  }
}
