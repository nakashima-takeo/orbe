import SwiftUI
import XCTest

@testable import Orbe

/// 右の欄（→ で入る）の項目と、右の欄の編集欄のキー。
extension TaskPaletteKeyTests {
  /// 右の欄の項目に入れた状態（焦点はカードの器へ移る）。
  private func enterDetail(_ model: TaskPaletteModel, at field: TaskDetailField) {
    model.enterDetail()
    model.area = .detail(.field(field))
  }

  /// 一覧から → で右の欄へ入る。
  func testRightArrowEntersTheDetailOfTheSelectedTask() {
    let model = model()

    send(.rightArrow, to: model)

    XCTAssertEqual(model.area, .detail(.field(.status)))
  }

  /// 完了はストアが待ちを外すので、→ を押し続けたリピートで未着手から完了まで進まない。
  func testHoldingRightArrowOnTheStatusStepsOnceAndKeepsTheWait() {
    let waiting = TaskItem.Waiting(reason: "レビュー待ち", since: DesignSceneFixtures.taskToday)
    let model = TaskPaletteSamples.model([
      TaskPaletteSamples.task(1, "a") { $0.wait = .waiting(waiting) }
    ])
    enterDetail(model, at: .status)

    send(.rightArrow, to: model)
    send(.rightArrow, repeating: true, to: model)
    send(.rightArrow, repeating: true, to: model)

    XCTAssertEqual(status(model, 1), .inProgress)
    XCTAssertNotNil(model.store.tasks.first?.wait, "待ちは消えない")
  }

  func testSpaceAndEscapeInDetail() {
    let model = model()
    enterDetail(model, at: .status)

    send(.escape, to: model)
    XCTAssertEqual(model.area, .list, "右の欄の esc は一覧へ戻る")

    enterDetail(model, at: .priority)
    send(.space, to: model)
    send(.space, repeating: true, to: model)
    XCTAssertEqual(status(model, 3), .done, "右の欄でも space はそのタスクに効く")
    XCTAssertEqual(model.area, .detail(.field(.priority)), "右の欄に居たまま")
  }

  /// 押し始めを見ていない space のリピートだけが届いても、何も完了にしない。
  func testSpaceKeyRepeatInDetailCompletesNothing() {
    let model = model()
    enterDetail(model, at: .priority)

    send(.space, repeating: true, to: model, expect: .ignored)

    XCTAssertEqual(model.store.tasks.map(\.status), [.todo, .todo, .todo])
    XCTAssertEqual(model.area, .detail(.field(.priority)))
  }

  func testEnterKeyRepeatAloneDoesNotStartEditing() {
    let model = model()
    enterDetail(model, at: .waiting)

    send(.return, repeating: true, to: model, expect: .ignored)

    XCTAssertNil(model.draft)
  }

  /// 編集中に esc を押し続けても、押し始めの esc で編集を終えて項目に留まる——続くリピートで一覧へ抜けたり画面を
  /// 閉じたりしない（押し始めと違う場所に届いたリピートは、場所のキーにせず流す）。
  func testEscapeHeldWhileEditingOnlyEndsTheEdit() {
    let model = model()
    var dismissed = false
    model.onDismiss = { dismissed = true }
    enterDetail(model, at: .waiting)
    send(.return, to: model)

    send(.escape, to: model)
    send(.escape, repeating: true, to: model, expect: .ignored)
    send(.escape, repeating: true, to: model, expect: .ignored)

    XCTAssertNil(model.draft)
    XCTAssertEqual(model.area, .detail(.field(.waiting)))
    XCTAssertFalse(dismissed)
  }

  /// ⌘↵ は 1 行の項目の確定のキーなので、文字の項目（編集していない状態）で押しても編集を始めない。そのタスクの
  /// agent を開くキーとして働く。
  func testCommandEnterOnATextFieldOpensTheAgentInsteadOfEditing() {
    let model = model()
    var opened: [Int] = []
    model.onOpenWorktreePalette = { opened.append($0) }

    for field in [TaskDetailField.title, .description] {
      enterDetail(model, at: field)
      send(.return, .command, to: model)
      XCTAssertNil(model.draft, "\(field): 編集は始めない")
      XCTAssertEqual(opened.last, model.selectedTask?.id, "\(field): agent を開く")
    }
  }

  // MARK: - 右の欄の Issue・PR の欄の行

  /// ↵ はその項目の GitHub のページを 1 回だけ開く。⌫ は押し続けても、押した 1 件だけを外す（焦点が
  /// 移った先の結び付きをリピートで外さない）。
  func testEnterOpensTheLinkOnceAndBackspaceUnlinksOnlyOneEvenWhenHeldDown() {
    let issue = TaskPaletteSamples.link(.issue, 1)
    let pullRequest = TaskPaletteSamples.link(.pr, 2)
    let model = TaskPaletteSamples.model(
      [
        TaskPaletteSamples.task(1, "a") { $0.links = [issue, pullRequest] },
        TaskPaletteSamples.task(2, "b"),
      ], githubItems: GitHubItemCache(fetch: { _, _ in }))
    var opened: [URL] = []
    model.onOpenURL = { opened.append($0) }
    model.tapRow(.task(1))
    model.enterDetail()
    model.area = .detail(.link(issue.item))

    send(.return, to: model)
    send(.return, repeating: true, to: model)
    send(.return, repeating: true, to: model)
    XCTAssertEqual(
      opened.map(\.absoluteString), ["https://github.com/o/n/issues/1"], "押し続けても開くのは 1 回だけ")

    send(.backspace, to: model)
    send(.backspace, repeating: true, to: model)
    send(.backspace, repeating: true, to: model)

    XCTAssertEqual(model.store.tasks.first?.links, [pullRequest], "外れるのは押した 1 件だけ")
    XCTAssertEqual(model.area, .detail(.link(pullRequest.item)))
  }

  // MARK: - 右の欄の agent の場所

  /// ↵ でその agent のタブへ移る。押し続けても移るのは 1 回だけ。
  func testEnterOnTheAgentGoesToItsTabOnce() {
    let agent = WorktreeAgentActivity.Agent(
      name: "claude", state: .waiting, since: DesignSceneFixtures.taskToday, tabId: 42,
      tabTitle: "issue-221", branch: nil,
      defaultBranch: nil)
    let model = TaskPaletteSamples.model(
      [TaskPaletteSamples.task(1, "a") { $0.worktree = TaskWorktree(key: "/r/wt/issue-221") }],
      agents: WorktreeAgentActivity(agents: ["/r/wt/issue-221": agent]))
    var focused: [Int] = []
    model.onFocusTab = { focused.append($0) }
    model.enterDetail()
    model.area = .detail(.agent)

    send(.return, to: model)
    send(.return, repeating: true, to: model)

    XCTAssertEqual(focused, [42])
  }
}
