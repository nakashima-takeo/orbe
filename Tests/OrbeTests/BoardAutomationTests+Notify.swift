import AppKit
import XCTest

@testable import Orbe

/// 地図の「通知」の段（見出しの「通知：…」の行）で開くサブメニュー「通知」。本物の `BoardView` を実窓に載せ、実 `NSEvent` の
/// キーとクリックを届ける。
///
/// 壊れると何が起きるか: 開いている間にほかの口が書き換えた定義を、通知を決めた拍子に上書きする。選んでいる段が替わっても
/// メニューが残り、別の自動化の横で決めてしまう。外のクリックが下の行まで届き、閉じるつもりで選択が動く。「通知」の行が詳細の
/// 見える範囲の外にあると開けない、または見えないまま開いている。
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

  /// 先頭の行が 12 ノードの地図を持つ（通知しない）。低い窓では詳細が見える高さを超える。
  private func tallDetailBoard() -> BoardModel {
    var samples = DesignSceneFixtures.boardMapSamples()
    samples[0].definition.notify = nil
    return board(samples)
  }

  /// 詳細のスクロール（ウィジェットの右端にあるもの）。
  private func detailScroll(in window: NSWindow) throws -> NSScrollView {
    func scrollViews(_ view: NSView) -> [NSScrollView] {
      (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
    let content = try XCTUnwrap(window.contentView)
    return try XCTUnwrap(
      scrollViews(content).max {
        $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
      })
  }

  /// 詳細をホイールで流したのと同じく、末尾まで送る（選択は動かない）。
  private func scrollToBottom(_ detail: NSScrollView, in window: NSWindow) throws {
    let document = try XCTUnwrap(detail.documentView)
    XCTAssertTrue(document.isFlipped, "前提: 上端が原点")
    detail.contentView.scroll(
      to: NSPoint(x: 0, y: document.bounds.height - detail.contentView.bounds.height))
    detail.reflectScrolledClipView(detail.contentView)
    flush(window)
    XCTAssertGreaterThan(detail.contentView.bounds.minY, 0, "前提: 詳細が流れた")
  }

  /// 詳細の中の「通知」の行の上端（見本の寸法: 上の余白 20・名前の行 21・間 4）。
  private static let notifyRowTop: CGFloat = 45

  /// 「通知」の行が見える範囲へ引き寄せられるのを待つ。引き寄せ（`scrollTo`）はキーを処理した後の RunLoop で効くので、決まった
  /// 時間だけ回すと遅い環境では引き寄せが後から効き、そのあと流した詳細を引き戻してしまう。
  private func waitForNotifyRow(_ detail: NSScrollView, in window: NSWindow) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while detail.contentView.bounds.minY > Self.notifyRowTop, Date() < deadline {
      pump(0.05)
    }
    flush(window)
    return detail.contentView.bounds.minY <= Self.notifyRowTop
  }

  /// 先頭の自動化の地図の「通知」の段を選び、詳細を末尾まで流して「通知」の行を見える範囲の外にした低い窓。
  private func mountWithTheNotifyRowScrolledOut(_ model: BoardModel) throws -> (
    NSWindow, NSScrollView
  ) {
    let window = mount(model, height: 400)
    down(window)
    right(window)
    up(window)
    XCTAssertEqual(model.automation.selectedMapStop, .notify, "前提: 「通知」の段")
    let detail = try detailScroll(in: window)
    try scrollToBottom(detail, in: window)
    return (window, detail)
  }

  /// 開いている間にほかの口（AI）が定義を書き換えていたら、決めても書かずに閉じ、断りの赤も出さない（書き換えた定義が残る）。
  func testChoosingAfterARewriteElsewhereWritesNothing() throws {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    openNotify(window)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)
    let current = try XCTUnwrap(automation.store.automation(id))
    var renamed = current.definition
    renamed.name = "AI が直した"
    _ = try automation.runner.set(id, version: current.version, renamed)
    flush(window)
    XCTAssertNotNil(automation.notifyCursor, "前提: 開いたまま")

    down(window)
    send(Key.enter, "\r", to: window)

    XCTAssertEqual(automation.store.automation(id)?.definition, renamed)
    XCTAssertEqual(automation.store.automation(id)?.version, current.version + 1)
    XCTAssertNil(automation.notifyCursor)
    XCTAssertNil(model.refusal)
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
    placeOffscreen(window)
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

  /// 「通知」の行が詳細の見える範囲の外にあっても、→ は行を見える範囲へ引き寄せてから開き、開いたまま選べる。
  func testOpeningBringsTheNotifyRowIntoView() throws {
    let model = tallDetailBoard()
    let automation = model.automation
    let (window, detail) = try mountWithTheNotifyRowScrolledOut(model)
    let id = try XCTUnwrap(automation.selectedAutomation?.id)

    right(window)

    XCTAssertTrue(waitForNotifyRow(detail, in: window), "「通知」の行が見える範囲へ戻る")
    XCTAssertEqual(automation.notifyCursor, 0, "見える範囲へ戻っても開いたまま")
    down(window)
    send(Key.enter, "\r", to: window)
    XCTAssertEqual(automation.store.automation(id)?.definition.notify, .menuBar)
  }

  /// 開いている間に「通知」の行が詳細の見える範囲から外れると閉じる。
  func testNotifyRowLeavingTheViewWhileOpenCloses() throws {
    let model = tallDetailBoard()
    let automation = model.automation
    let (window, detail) = try mountWithTheNotifyRowScrolledOut(model)
    right(window)
    XCTAssertTrue(waitForNotifyRow(detail, in: window), "前提: 開くときの引き寄せが効き終わった")
    XCTAssertEqual(automation.notifyCursor, 0, "前提: 開いている")

    try scrollToBottom(detail, in: window)

    XCTAssertNil(automation.notifyCursor)
    XCTAssertEqual(automation.selectedMapStop, .notify, "段は動かない")
  }
}
