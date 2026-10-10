import AppKit
import XCTest

@testable import Orbe

/// 押した瞬間だけ効くキー（入力欄の ⌘↵・条件の箱の ↵・会話の行の ↵）は、押し続けても 1 回だけ効く。
///
/// 壊れると何が起きるか: ⌘↵ を長押しすると、頼んだ後に空になった入力欄から、関係の無い先頭タスクの頼む欄が開く。条件の箱が
/// 開閉を繰り返す。会話のタブへ何度も移る。
extension TaskPaletteCardKeyTests {
  /// 待っている条件に会話が付き、その会話のタブが開いているタスク 1 つ。
  private func waitingWithConversation() -> (TaskPaletteModel, AgentSessionTabs) {
    let tabs = AgentSessionTabs()
    tabs.update([.init(sessionId: "s-1", tab: .init(tabId: 7, title: "pr-214"), isDormant: false)])
    let condition = WaitCondition(
      WaitConditionRequest(
        description: "レビューが付いたら", command: "gh pr view 214", everyMinutes: 10,
        deadline: DesignSceneFixtures.taskToday.addingTimeInterval(86400),
        conversation: WaitConversation(
          command: "claude", sessionId: "s-1", workspace: nil, secretary: false)),
      setAt: DesignSceneFixtures.taskToday)
    let model = TaskPaletteSamples.model(
      [
        TaskPaletteSamples.task(1, "a") {
          $0.wait = .waiting(
            TaskItem.Waiting(
              reason: "レビュー待ち", since: DesignSceneFixtures.taskToday, condition: condition))
        }
      ], sessionTabs: tabs)
    return (model, tabs)
  }

  func testCommandEnterHeldDownInTheFieldAsksOnce() {
    let model = model()
    var asks: [SecretaryAsk] = []
    model.onAskSecretary = {
      asks.append($0)
      return .success(.accepted)
    }
    let window = mount(model)
    type("見積もり", into: window)

    press(Key.enter, "\r", .command, to: window)
    press(Key.enter, "\r", .command, repeating: true, to: window)
    press(Key.enter, "\r", .command, repeating: true, to: window)

    XCTAssertEqual(asks, [.text("見積もり")])
    XCTAssertNil(model.draft, "空になった入力欄から先頭のタスクの頼む欄を開かない")
  }

  func testEnterHeldDownOnTheConditionBoxTogglesOnce() {
    let (model, _) = waitingWithConversation()
    let window = mount(model)
    model.enterDetail()
    model.area = .detail(.condition(.log))
    flush(window)

    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)
    press(Key.enter, "\r", repeating: true, to: window)

    XCTAssertTrue(model.isConditionPartOpen(.log), "開閉を繰り返さない")
  }

  func testEnterHeldDownOnTheConversationRowGoesToItsTabOnce() {
    let (model, _) = waitingWithConversation()
    var focused: [Int] = []
    model.onFocusTab = { focused.append($0) }
    let window = mount(model)
    model.enterDetail()
    model.area = .detail(.conversation)
    flush(window)

    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)

    XCTAssertEqual(focused, [7])
  }
}
