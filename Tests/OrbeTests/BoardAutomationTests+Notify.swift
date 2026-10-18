import AppKit
import XCTest

@testable import Orbe

/// 地図の「通知」の段（見出しの「通知：…」の行）で開くサブメニュー「通知」。本物の `BoardView` を実窓に載せ、実 `NSEvent` の
/// キーとクリックを届ける。
///
/// 壊れると何が起きるか: 通知を替えたつもりが替わらない・別の自動化が替わる。替えた拍子に走っている回が止まる。開いている間の
/// space・↵・⌘⌫・⌘↵ が下の地図や一覧へ抜けて、止める・実行・削除が起きる。選んでいる段が替わってもメニューが残り、別の
/// 自動化の横で決めてしまう。外のクリックが下の行まで届き、閉じるつもりで選択が動く。
extension BoardAutomationTests {
  /// 先頭の行（失敗の Backlog）の「通知」の行で開いたときの、メニューの行と外の窓の中の点（1200×700 の窓）。
  private enum NotifyPoint {
    static let menuBarRow = NSPoint(x: 512, y: 531)
    /// メニューの外で、一覧の 2 行目。
    static let secondRow = NSPoint(x: 120, y: 536)
  }

  /// 一覧の先頭の行から地図へ入り、「通知」の段で → を押して開く。
  private func openNotify(_ window: NSWindow) {
    down(window)
    right(window)
    up(window)
    right(window)
  }

  private func notifyLine(_ automation: BoardAutomationModel, _ id: Int) -> String? {
    let text = automation.text(LocalizationStore(language: .ja), now: automation.runner.now())
    return automation.detail(id, text: text, now: automation.runner.now())?.notify
  }

  /// 「通知」の段の → で開くと今の設定（通知しない）の行から。↓ ↵ でその自動化の通知だけがメニューバーに替わり、見出しが
  /// 追従して閉じる。↵ でも開き、開き直すと印の行から始まり、↑ は端で巡回する。
  func testTheNotifyRowOpensAtTheCurrentSettingAndReturnChoosesIt() throws {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    openNotify(window)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)
    let before = try XCTUnwrap(automation.store.automation(id)).definition
    XCTAssertNil(before.notify, "前提: 見本は通知しない")

    XCTAssertEqual(automation.notifyCursor, 0)
    XCTAssertEqual(automation.hints.map(\.key), ["↑↓", "↵", "←"])
    down(window)
    send(Key.enter, "\r", to: window)

    var expected = before
    expected.notify = .menuBar
    XCTAssertEqual(automation.store.automation(id)?.definition, expected, "通知だけが替わる")
    XCTAssertNil(automation.notifyCursor)
    XCTAssertEqual(notifyLine(automation, id), "通知：メニューバー")
    XCTAssertEqual(automation.selectedMapStop, .notify, "段は動かない")
    XCTAssertTrue(
      automation.store.automations.filter { $0.id != id }.allSatisfy {
        $0.definition.notify == nil
      },
      "ほかの自動化は替わらない")

    send(Key.enter, "\r", to: window)
    XCTAssertEqual(automation.notifyCursor, 1, "印の行から")
    up(window)
    up(window)
    XCTAssertEqual(automation.notifyCursor, 2, "端で巡回する")
  }

  /// ← と esc は何も変えずに閉じ、「通知」の段に戻る。部品の段の → は開かない。
  func testLeftAndEscapeCloseWithoutChanging() {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    openNotify(window)

    down(window)
    left(window)
    XCTAssertNil(automation.notifyCursor)
    right(window)
    down(window)
    send(Key.escape, "\u{1B}", to: window)
    XCTAssertNil(automation.notifyCursor)

    XCTAssertEqual(automation.store.automations, untouched)
    XCTAssertEqual(automation.selectedMapStop, .notify, "閉じると「通知」の段")
    down(window)
    right(window)
    XCTAssertNil(automation.notifyCursor, "部品の段の → は開かない")
  }

  /// 開いている間は、下のキー（space・↵ のリピート・⌘⌫・⌘↵・↑↓）は地図にも一覧にも効かない。
  func testKeysWhileOpenDoNotReachBelow() {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    openNotify(window)
    let selected = automation.selectedAutomation?.id

    send(Key.space, " ", to: window)
    send(Key.enter, "\r", repeating: true, to: window)
    send(Key.delete, "\u{7F}", .command, to: window)
    send(Key.enter, "\r", .command, to: window)
    down(window)

    XCTAssertEqual(automation.notifyCursor, 1, "↓ はメニューの中を動き、ほかのキーは握られる")
    XCTAssertEqual(automation.selectedAutomation?.id, selected)
    XCTAssertEqual(automation.selectedMapStop, .notify)
    XCTAssertEqual(automation.store.automations, untouched, "どれも変わらない")
    XCTAssertFalse(automation.store.automations.contains { automation.runner.isRunning($0.id) })
  }

  /// 通知だけを替えても、走っている回は止まらない。
  func testChoosingWhileRunningKeepsTheRun() throws {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    down(window)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)
    send(Key.enter, "\r", .command, to: window)
    XCTAssertTrue(automation.runner.isRunning(id), "前提: 走っている")

    right(window)
    up(window)
    right(window)
    up(window)
    send(Key.enter, "\r", to: window)

    XCTAssertEqual(automation.store.automation(id)?.definition.notify, .notificationCenter)
    XCTAssertTrue(automation.runner.isRunning(id))
  }

  /// 段が変わると閉じる: 外から入る・ピルから行を指す・選んでいる自動化がほかの口で消える・地図を出る。
  func testChangingTheSelectionCloses() throws {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    openNotify(window)

    automation.enter()
    XCTAssertNil(automation.notifyCursor, "外から入ると欄が選ばれる")

    openNotify(window)
    automation.open(Self.github)
    XCTAssertNil(automation.notifyCursor, "ピルから別の行を指す")

    right(window)
    up(window)
    right(window)
    XCTAssertNotNil(automation.notifyCursor, "前提: 開いている")
    try automation.runner.delete(Self.github)
    flush(window)
    XCTAssertNil(automation.notifyCursor, "消えて選択が移る")
    XCTAssertEqual(automation.selectedAutomation?.id, Self.pausedGmail)
    XCTAssertEqual(automation.place, .list, "移った先の自動化の段を勝手に選ばない")

    automation.tapNotify()
    automation.leaveMap()
    XCTAssertNil(automation.notifyCursor, "地図を出ると閉じる")
  }

  /// メニューの行のクリックで決まり、外のクリックは閉じるだけで下の行を選ばない。
  func testClickingARowChoosesAndClickingOutsideOnlyCloses() {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    openNotify(window)

    click(NotifyPoint.secondRow, in: window)
    XCTAssertNil(automation.notifyCursor)
    XCTAssertEqual(automation.selectedAutomation?.id, Self.failingBacklog, "下の行へ届かない")

    right(window)
    click(NotifyPoint.menuBarRow, in: window)
    XCTAssertNil(automation.notifyCursor)
    XCTAssertEqual(automation.store.automation(Self.failingBacklog)?.definition.notify, .menuBar)
    XCTAssertEqual(automation.place, .map)
  }
}
