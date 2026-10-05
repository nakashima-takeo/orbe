import AppKit
import XCTest

@testable import Orbe

/// タスク画面の ⌘T が、焦点の居場所（ヘッダーの入力欄・詳細のカード・詳細の編集欄）に依らず窓のキーの経路で
/// 受けられ、選んでいるタスクのための ⌘T に差し替わることを、実 `WindowController` の窓に実 `NSEvent` を
/// 渡して固定する。
///
/// キーは窓の `performKeyEquivalent` へ渡す。AppKit は ⌘ 付きのキーを、first responder の `keyDown` より先に
/// key window のこの入口へ流す（ここで消費されれば入力欄には届かない）。テストの窓は非アクティブなアプリの
/// 窓で key window になれず、`NSApp.sendEvent` はこの入口を通らないため、入口を直接叩く。
///
/// 壊れると何が起きるか: 詳細を見ているときや、詳細を打っている途中に ⌘T を押しても何も起きない（または
/// 入力欄に文字として入る）。詳細を打ちかけのまま ⌘T を押すと、打った内容が消える。追加の行で ⌘T を
/// 押しても、タスクが足されないまま ⌘T が開く。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerTaskWorktreePaletteTests: OrbeTestCase {
  private func launch() throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    return WindowController()
  }

  /// タスク 1 件を足してタスク画面を開き、そのタスクを選んだ状態。
  private func openTaskPalette(_ wc: WindowController) throws -> (TaskPaletteModel, TaskItem) {
    let task = try wc.taskStore.add(TaskDraft(title: "見積もりを出す"))
    XCTAssertTrue(wc.handleWindowKeyCommand(.showTaskPalette))
    let palette = try XCTUnwrap(wc.model.taskPalette)
    palette.reconcile()
    XCTAssertEqual(palette.selectedID, .task(task.id), "前提: そのタスクを選んでいる")
    return (palette, task)
  }

  private func pump(_ seconds: TimeInterval = 0.3) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
  }

  /// ⌘T を窓へ渡す。消費されたら true。
  private func pressCommandT(_ wc: WindowController) throws -> Bool {
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: wc.window.windowNumber,
        context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false,
        keyCode: 17))
    let consumed = wc.window.performKeyEquivalent(with: event)
    pump()
    return consumed
  }

  private func assertOpenedTheWorktreePalette(
    for task: TaskItem, in wc: WindowController, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(wc.presentedOverlay, .worktreePalette, "⌘T に差し替わる", file: file, line: line)
    XCTAssertNil(wc.model.taskPalette, "タスク画面は畳まれる", file: file, line: line)
    XCTAssertEqual(
      wc.model.worktreePalette?.taskContextID, task.id, "選んでいたタスクのための ⌘T", file: file,
      line: line)
  }

  func testCommandTWithTheInputFieldFocusedOpensTheWorktreePaletteForTheSelectedTask() throws {
    let wc = try launch()
    let (palette, task) = try openTaskPalette(wc)
    pump()
    XCTAssertEqual(palette.focusTarget, .field)
    XCTAssertTrue(wc.window.firstResponder is NSText, "前提: 焦点はヘッダーの入力欄にある")

    XCTAssertTrue(try pressCommandT(wc), "窓のキーの経路で消費され、入力欄へは流れない")

    assertOpenedTheWorktreePalette(for: task, in: wc)
  }

  func testCommandTWithTheDetailCardFocusedOpensTheWorktreePaletteForTheSelectedTask() throws {
    let wc = try launch()
    let (palette, task) = try openTaskPalette(wc)
    palette.enterDetail()
    pump()
    XCTAssertEqual(palette.focusTarget, .card)
    XCTAssertFalse(wc.window.firstResponder is NSText, "前提: 焦点は詳細のカード（文字の入力欄ではない）")

    XCTAssertTrue(try pressCommandT(wc))

    assertOpenedTheWorktreePalette(for: task, in: wc)
  }

  func testCommandTWhileEditingTheDescriptionCommitsItThenOpensTheWorktreePalette() throws {
    let wc = try launch()
    let (palette, task) = try openTaskPalette(wc)
    palette.enterDetail()
    palette.tapField(.description)
    pump()
    palette.draftText = "打ちかけの詳細"
    XCTAssertEqual(palette.focusTarget, .edit(.description))
    XCTAssertTrue(wc.window.firstResponder is NSText, "前提: 焦点は詳細の詳細の編集欄にある")

    XCTAssertTrue(try pressCommandT(wc))

    assertOpenedTheWorktreePalette(for: task, in: wc)
    XCTAssertEqual(
      wc.taskStore.tasks.first { $0.id == task.id }?.description, "打ちかけの詳細", "打っていた詳細は確定してから開く")
  }

  func testCommandTOnTheAddRowAddsTheTaskThenOpensItsWorktreePalette() throws {
    let wc = try launch()
    XCTAssertTrue(wc.handleWindowKeyCommand(.showTaskPalette))
    let palette = try XCTUnwrap(wc.model.taskPalette)
    palette.query = "請求書を送る"
    XCTAssertEqual(palette.selectedID, .add, "前提: 追加の行を選んでいる")

    XCTAssertTrue(try pressCommandT(wc))

    let added = try XCTUnwrap(wc.taskStore.tasks.last)
    XCTAssertEqual(added.title, "請求書を送る", "タスクが足される")
    assertOpenedTheWorktreePalette(for: added, in: wc)
  }
}
