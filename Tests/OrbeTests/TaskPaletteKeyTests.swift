import SwiftUI
import XCTest

@testable import Orbe

/// タスク画面（⌘⇧X）のキーの入口 `TaskPaletteModel.handleKey` に、キー 1 打の値を直接渡して、焦点の行き先（入力欄 /
/// 右の欄の項目 / 右の欄の編集欄 / 提案タブの棚）ごとに、キーが意図した操作になること、入力欄へ届けてはいけないキーを
/// 握ることを固定する。
///
/// 壊れると何が起きるか: ⌘⌫ や space を押し続けたリピートで、次のタスクまで消える・完了になる。⌘↵ が ↵ の確定へ流れて、
/// 入力欄に打った文がタスクとして足される・提案タブで選んだ候補の次の候補までタスクになる。esc を押し続けると一段より深く抜けて画面が閉じる。右の欄の
/// ↵ を押し続けると、同じページを何度も開く・条件の箱が開閉を繰り返す。
@MainActor
final class TaskPaletteKeyTests: OrbeTestCase {
  func model() -> TaskPaletteModel { TaskPaletteSamples.threeTodos() }

  /// キー 1 打を入口へ渡し、握るか流すかを確かめる。既定は握る。
  func send(
    _ key: KeyEquivalent, _ modifiers: EventModifiers = [], repeating: Bool = false,
    to model: TaskPaletteModel, expect result: KeyPress.Result = .handled,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      model.handleKey(KeyInput(key, modifiers: modifiers, isRepeat: repeating)), result,
      result == .handled ? "握る（入力欄へ届けない）" : "流す（入力欄へ届ける）", file: file, line: line)
  }

  func status(_ model: TaskPaletteModel, _ id: Int) -> TaskItem.Status? {
    model.store.tasks.first { $0.id == id }?.status
  }

  /// 待っている条件に会話が付き、その会話のタブが開いているタスク 1 つ。
  private func waitingWithConversation() -> TaskPaletteModel {
    let tabs = AgentSessionTabs()
    tabs.update([.init(sessionId: "s-1", tab: .init(tabId: 7, title: "pr-214"), isDormant: false)])
    let condition = WaitCondition(
      WaitConditionRequest(
        description: "レビューが付いたら", command: "gh pr view 214", everyMinutes: 10,
        deadline: DesignSceneFixtures.taskToday.addingTimeInterval(86400),
        conversation: WaitConversation(
          command: "claude", sessionId: "s-1", workspace: nil)),
      setAt: DesignSceneFixtures.taskToday)
    return TaskPaletteSamples.model(
      [
        TaskPaletteSamples.task(1, "a") {
          $0.wait = .waiting(
            TaskItem.Waiting(
              reason: "レビュー待ち", since: DesignSceneFixtures.taskToday, condition: condition))
        }
      ], sessionTabs: tabs)
  }

  // MARK: - 入力欄（一覧）

  /// 入力欄の ⌘↵ は onSubmit（↵ = 追加）へ流れず、打った文を agent に任せる。タスクの行を選んで ⌘↵ なら、そのタスクの
  /// agent を開く。
  func testCommandEnterInTheFieldHandsTheTextOverAndOnARowOpensTheAgent() {
    let model = model()
    var asks: [String] = []
    model.onAskSecretary = {
      asks.append($0)
      return nil
    }
    var opened: [Int] = []
    model.onOpenWorktreePalette = { opened.append($0) }
    model.query = "見積もり"

    send(.return, .command, to: model)
    XCTAssertEqual(asks, ["見積もり"])
    XCTAssertEqual(model.store.tasks.count, 3, "足さない")

    send(.return, .command, to: model)
    XCTAssertEqual(opened, [3], "選んでいる行のタスクの agent を開く")
    XCTAssertEqual(asks.count, 1)
  }

  /// 行の ⌘↵ は、待ちが解けたタスクなら、一覧でも右の欄でも ⌘T の画面を開かずに会話を続きから始める。
  func testCommandEnterOnAResolvedWaitContinuesTheConversationFromTheListAndTheDetail() {
    let condition = WaitCondition(
      WaitConditionRequest(
        description: "レビューが付いたら", command: "gh pr view 214", everyMinutes: 10,
        deadline: DesignSceneFixtures.taskToday.addingTimeInterval(86400),
        conversation: WaitConversation(command: "claude", sessionId: "s-1", workspace: nil)),
      setAt: DesignSceneFixtures.taskToday)
    let model = TaskPaletteSamples.model([
      TaskPaletteSamples.task(1, "a", .inProgress) {
        $0.wait = .resolved(
          WaitResolution(
            waiting: TaskItem.Waiting(
              reason: "レビュー待ち", since: DesignSceneFixtures.taskToday, condition: condition),
            how: .satisfied(output: "レビューが付いた"), at: DesignSceneFixtures.taskToday))
      }
    ])
    var continued: [Int] = []
    var opened: [Int] = []
    model.onContinueWait = {
      continued.append($0)
      return nil
    }
    model.onOpenWorktreePalette = { opened.append($0) }
    XCTAssertEqual(model.selectedID, .task(1), "前提")

    send(.return, .command, to: model)
    model.enterDetail()
    send(.return, .command, to: model)

    XCTAssertEqual(continued, [1, 1])
    XCTAssertEqual(opened, [])
  }

  func testCommandBackspaceDeletesOneTaskEvenWhenHeldDown() {
    let model = model()

    send(.backspace, .command, to: model)
    send(.backspace, .command, repeating: true, to: model)
    send(.backspace, .command, repeating: true, to: model)

    XCTAssertEqual(model.store.tasks.map(\.id), [1, 2], "消えるのは押した 1 件だけ")
  }

  func testSpaceHeldDownCompletesOneTaskAndTypesNoSpace() {
    let model = model()

    send(.space, to: model)
    send(.space, repeating: true, to: model)

    XCTAssertEqual(model.store.tasks.map(\.status), [.todo, .todo, .done], "完了は押した 1 件だけ")
    XCTAssertEqual(model.query, "", "リピートは入力欄に空白を入れない")
  }

  func testOptionArrowsMoveLikeArrowsAndCommandArrowsJump() {
    let model = model()

    send(.downArrow, .command, to: model)
    XCTAssertEqual(model.selectedID, .task(1), "⌘↓ で末尾へ")

    send(.upArrow, .option, to: model)
    XCTAssertEqual(model.selectedID, .task(2), "⌥↑ は ↑ と同じく前の行へ")
  }

  func testEscapeInTheListClosesTheScreen() {
    let model = model()
    var dismissed = false
    model.onDismiss = { dismissed = true }

    send(.escape, to: model)

    XCTAssertTrue(dismissed)
  }

  func testEscapeClosesTheOpenFilterMenuBeforeTheScreen() {
    let model = model()
    var dismissed = false
    model.onDismiss = { dismissed = true }
    model.toggleFilterMenu(.workspace)

    send(.escape, to: model)
    XCTAssertNil(model.openFilterMenu)
    XCTAssertFalse(dismissed, "メニューだけを閉じる")

    send(.escape, to: model)
    XCTAssertTrue(dismissed)
  }

  // MARK: - 押した瞬間だけ効くキー

  /// 入力欄に打った文を ⌘↵ で agent に任せ、そのまま長押ししても、空になった入力欄から、関係の無い先頭タスクの agent を
  /// 開かない。
  func testCommandEnterHeldDownInTheFieldAsksOnce() {
    let model = model()
    var asks: [String] = []
    model.onAskSecretary = {
      asks.append($0)
      return nil
    }
    var opened: [Int] = []
    model.onOpenWorktreePalette = { opened.append($0) }
    model.query = "見積もり"

    send(.return, .command, to: model)
    send(.return, .command, repeating: true, to: model)
    send(.return, .command, repeating: true, to: model)

    XCTAssertEqual(asks, ["見積もり"])
    XCTAssertEqual(opened, [], "空になった入力欄から先頭のタスクの agent を開かない")
  }

  func testEnterHeldDownOnTheConditionBoxTogglesOnce() {
    let model = waitingWithConversation()
    model.enterDetail()
    model.area = .detail(.condition(.log))

    send(.return, to: model)
    send(.return, repeating: true, to: model)
    send(.return, repeating: true, to: model)

    XCTAssertTrue(model.isConditionPartOpen(.log), "開閉を繰り返さない")
  }

  func testEnterHeldDownOnTheConversationRowGoesToItsTabOnce() {
    let model = waitingWithConversation()
    var focused: [Int] = []
    model.onFocusTab = { focused.append($0) }
    model.enterDetail()
    model.area = .detail(.conversation)

    send(.return, to: model)
    send(.return, repeating: true, to: model)

    XCTAssertEqual(focused, [7])
  }
}
