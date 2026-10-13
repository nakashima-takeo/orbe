import AppKit
import XCTest

@testable import Orbe

/// 一覧の行の → で開くサブメニュー「通知」。本物の `BoardView` を実窓に載せ、実 `NSEvent` のキーとクリックを届ける。
///
/// 壊れると何が起きるか: 通知を替えたつもりが替わらない・別の自動化が替わる。替えた拍子に走っている回が止まる。開いている間の
/// space・↵・⌘⌫ が下の一覧へ抜けて、止める・今すぐ実行・削除が起きる。選んでいる行が替わってもメニューが残り、別の自動化の
/// 横で決めてしまう。外のクリックが下の行まで届き、閉じるつもりで選択が動く。
extension BoardAutomationTests {
  private enum NotifyKey {
    static let left: UInt16 = 123
    static let right: UInt16 = 124
  }

  /// 先頭の行（失敗の Backlog）を選んで開いたときの、メニューの行と外の窓の中の点（1200×700 の窓）。
  private enum NotifyPoint {
    static let menuBarRow = NSPoint(x: 430, y: 548)
    /// メニューの外で、一覧の 2 行目。
    static let secondRow = NSPoint(x: 120, y: 536)
  }

  func right(_ window: NSWindow) {
    send(NotifyKey.right, "\u{F703}", [.numericPad, .function], to: window)
  }

  func left(_ window: NSWindow) {
    send(NotifyKey.left, "\u{F702}", [.numericPad, .function], to: window)
  }

  private func outputNotes(_ automation: BoardAutomationModel, _ id: Int) -> [String] {
    let text = automation.text(LocalizationStore(language: .ja), now: automation.runner.now())
    return automation.summary(id, text: text)?.nodes.last?.notes ?? []
  }

  /// → で開くと今の設定（通知しない）の行から。↓ ↵ でその自動化の通知だけがメニューバーに替わり、注記が追従して閉じる。
  /// 開き直すと印の行から始まり、↑ は端で巡回する。
  func testArrowRightOpensAtTheCurrentSettingAndReturnChoosesIt() throws {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    down(window)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)
    let before = try XCTUnwrap(automation.store.automation(id)).definition
    XCTAssertNil(before.notify, "前提: 見本は通知しない")

    right(window)
    XCTAssertEqual(automation.notifyCursor, 0)
    XCTAssertEqual(automation.hints.map(\.key), ["↑↓", "↵", "←"])
    down(window)
    send(Key.enter, "\r", to: window)

    var expected = before
    expected.notify = .menuBar
    XCTAssertEqual(automation.store.automation(id)?.definition, expected, "通知だけが替わる")
    XCTAssertNil(automation.notifyCursor)
    XCTAssertEqual(outputNotes(automation, id).last, "通知：メニューバー", "注記のいちばん下")
    XCTAssertEqual(automation.selectedAutomation?.id, id, "選択は動かない")
    XCTAssertTrue(
      automation.store.automations.filter { $0.id != id }.allSatisfy {
        $0.definition.notify == nil
      },
      "ほかの自動化は替わらない")

    right(window)
    XCTAssertEqual(automation.notifyCursor, 1, "印の行から")
    up(window)
    up(window)
    XCTAssertEqual(automation.notifyCursor, 2, "端で巡回する")
  }

  /// ← と esc は何も変えずに閉じる。
  func testLeftAndEscapeCloseWithoutChanging() {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    down(window)

    right(window)
    down(window)
    left(window)
    XCTAssertNil(automation.notifyCursor)
    right(window)
    down(window)
    send(Key.escape, "\u{1B}", to: window)
    XCTAssertNil(automation.notifyCursor)

    XCTAssertEqual(automation.store.automations, DesignSceneFixtures.boardAutomations())
    XCTAssertEqual(automation.place, .list, "esc は欄へ移らない")
  }

  /// 開いている間は、下の一覧のキー（space・↵ のリピート・⌘⌫・⌘↵・↑↓）は一覧に効かない。
  func testKeysWhileOpenDoNotReachTheList() {
    let model = board()
    let automation = model.automation
    var asked = false
    automation.onAsk = { _ in
      asked = true
      return nil
    }
    let window = mount(model)
    down(window)
    let selected = automation.selectedAutomation?.id

    right(window)
    send(Key.space, " ", to: window)
    send(Key.enter, "\r", repeating: true, to: window)
    send(Key.delete, "\u{7F}", .command, to: window)
    send(Key.enter, "\r", .command, to: window)
    down(window)

    XCTAssertEqual(automation.notifyCursor, 1, "↓ はメニューの中を動き、ほかのキーは握られる")
    XCTAssertEqual(automation.selectedAutomation?.id, selected)
    XCTAssertEqual(automation.store.automations, DesignSceneFixtures.boardAutomations(), "どれも変わらない")
    XCTAssertFalse(automation.store.automations.contains { automation.runner.isRunning($0.id) })
    XCTAssertFalse(asked, "⌘↵ で直しを頼まない")
  }

  /// 通知だけを替えても、走っている回は止まらない。
  func testChoosingWhileRunningKeepsTheRun() throws {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    down(window)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)
    send(Key.enter, "\r", to: window)
    XCTAssertTrue(automation.runner.isRunning(id), "前提: 走っている")

    right(window)
    up(window)
    send(Key.enter, "\r", to: window)

    XCTAssertEqual(automation.store.automation(id)?.definition.notify, .notificationCenter)
    XCTAssertTrue(automation.runner.isRunning(id))
  }

  /// 選んでいる段が変わると閉じる: 外から入る・ピルから行を指す・選んでいる自動化がほかの口で消える。
  func testChangingTheSelectionCloses() throws {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    down(window)

    right(window)
    automation.enter()
    XCTAssertNil(automation.notifyCursor, "外から入ると欄が選ばれる")

    down(window)
    right(window)
    automation.open(Self.github)
    XCTAssertNil(automation.notifyCursor, "ピルから別の行を指す")

    right(window)
    try automation.runner.delete(Self.github)
    flush(window)
    XCTAssertNil(automation.notifyCursor, "消えて選択が移る")
    XCTAssertEqual(automation.selectedAutomation?.id, Self.pausedGmail)
  }

  /// メニューの行のクリックで決まり、外のクリックは閉じるだけで下の行を選ばない。
  func testClickingARowChoosesAndClickingOutsideOnlyCloses() {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    down(window)

    right(window)
    click(NotifyPoint.secondRow, in: window)
    XCTAssertNil(automation.notifyCursor)
    XCTAssertEqual(automation.selectedAutomation?.id, Self.failingBacklog, "下の行へ届かない")

    right(window)
    click(NotifyPoint.menuBarRow, in: window)
    XCTAssertNil(automation.notifyCursor)
    XCTAssertEqual(automation.store.automation(Self.failingBacklog)?.definition.notify, .menuBar)
    XCTAssertEqual(automation.place, .list)
  }
}
