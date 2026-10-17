import AppKit
import XCTest

@testable import Orbe

/// 一覧の行の → で開くサブメニュー「通知」。本物の `BoardView` を実窓に載せ、実 `NSEvent` のキーとクリックを届ける。
///
/// 壊れると何が起きるか: 通知を替えたつもりが替わらない・別の自動化が替わる。替えた拍子に走っている回が止まる。開いている間の
/// space・↵・⌘⌫ が下の一覧へ抜けて、止める・今すぐ実行・削除が起きる。選んでいる行が替わってもメニューが残り、別の自動化の
/// 横で決めてしまう。外のクリックが下の行まで届き、閉じるつもりで選択が動く。
extension BoardAutomationTests {
  /// 先頭の行（失敗の Backlog）を選んで開いたときの、メニューの行と外の窓の中の点（1200×700 の窓）。
  private enum NotifyPoint {
    static let menuBarRow = NSPoint(x: 430, y: 548)
    /// メニューの外で、一覧の 2 行目。
    static let secondRow = NSPoint(x: 120, y: 536)
  }

  /// 見本の 4 件に、まだ回っていない自動化を足して一覧が見える範囲より長くなる並び。先頭の行は見本と同じ失敗の Backlog。
  private func longBoard() -> BoardModel {
    let samples = DesignSceneFixtures.boardAutomationSamples()
    let extra = (5...24).map { _ in
      AutomationSample(
        definition: samples[0].definition, createdAt: Date(timeIntervalSince1970: 0))
    }
    return board(samples + extra)
  }

  /// 一覧のスクロール（部品の左端にあるもの）。
  private func listScroll(in window: NSWindow) throws -> NSScrollView {
    func scrollViews(_ view: NSView) -> [NSScrollView] {
      (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
    let content = try XCTUnwrap(window.contentView)
    return try XCTUnwrap(
      scrollViews(content).min {
        $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
      })
  }

  /// 一覧をホイールで流したのと同じく、末尾まで送る（選択は動かない）。
  private func scrollToBottom(_ list: NSScrollView, in window: NSWindow) throws {
    let document = try XCTUnwrap(list.documentView)
    XCTAssertTrue(document.isFlipped, "前提: 上端が原点")
    list.contentView.scroll(
      to: NSPoint(x: 0, y: document.bounds.height - list.contentView.bounds.height))
    list.reflectScrolledClipView(list.contentView)
    flush(window)
    XCTAssertGreaterThan(list.contentView.bounds.minY, 0, "前提: 一覧が流れた")
  }

  /// 一覧が先頭まで戻るのを待つ。行の引き寄せ（`scrollTo`）はキーを処理した後の RunLoop で効くので、決まった時間だけ回すと
  /// 遅い環境では引き寄せが後から効き、そのあと流した一覧を先頭へ戻してしまう。
  private func waitForTop(_ list: NSScrollView, in window: NSWindow) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while list.contentView.bounds.minY != 0, Date() < deadline {
      pump(0.05)
    }
    flush(window)
    return list.contentView.bounds.minY == 0
  }

  /// 先頭の行を選び、一覧を末尾まで流して先頭の行を見える範囲の外にした窓。引き寄せが残っていない状態で返す: 流してから
  /// 先頭の行を選び、その引き寄せで一覧が先頭へ戻るのを見届けてから流し直す。
  private func mountWithTheFirstRowScrolledOut(_ model: BoardModel) throws -> (
    NSWindow, NSScrollView
  ) {
    let window = mount(model)
    let list = try listScroll(in: window)
    try scrollToBottom(list, in: window)
    down(window)
    XCTAssertEqual(model.automation.selectedAutomation?.id, Self.failingBacklog)
    XCTAssertTrue(waitForTop(list, in: window), "前提: 選んだ先頭の行が引き寄せられる")
    try scrollToBottom(list, in: window)
    return (window, list)
  }

  private func outputNotes(_ automation: BoardAutomationModel, _ id: Int) -> [String] {
    let text = automation.text(LocalizationStore(language: .ja), now: automation.runner.now())
    return automation.summary(id, text: text)?.notes ?? []
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

    XCTAssertEqual(automation.store.automations, untouched)
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
    XCTAssertEqual(automation.store.automations, untouched, "どれも変わらない")
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

  /// 選んでいる行が一覧の見える範囲の外にあっても、→ は行を見える範囲へ引き寄せてから、その横に開く。
  func testArrowRightBringsTheRowIntoViewAndOpensBesideIt() throws {
    let model = longBoard()
    let automation = model.automation
    let (window, list) = try mountWithTheFirstRowScrolledOut(model)

    right(window)

    XCTAssertEqual(automation.notifyCursor, 0)
    XCTAssertTrue(waitForTop(list, in: window), "先頭の行が見える範囲へ戻る")
    click(NotifyPoint.menuBarRow, in: window)
    XCTAssertEqual(
      automation.store.automation(Self.failingBacklog)?.definition.notify, .menuBar,
      "メニューは選んでいる行の横に出る")
  }

  /// 開いている間に選んでいる行が一覧の見える範囲から外れると閉じる。
  func testRowLeavingTheViewWhileOpenCloses() throws {
    let model = longBoard()
    let automation = model.automation
    let (window, list) = try mountWithTheFirstRowScrolledOut(model)
    right(window)
    XCTAssertTrue(waitForTop(list, in: window), "前提: 開くときの引き寄せが効き終わった")
    XCTAssertEqual(automation.notifyCursor, 0, "前提: 開いている")

    try scrollToBottom(list, in: window)

    XCTAssertNil(automation.notifyCursor)
    XCTAssertEqual(automation.selectedAutomation?.id, Self.failingBacklog, "選択は動かない")
  }
}
