import AppKit
import XCTest

@testable import Orbe

/// 自動化のウィジェットの中の焦点——依頼の欄と一覧の行き来。本物の `BoardView` を実窓に載せ、実 `NSEvent` のキーとクリックを届ける。
///
/// 壊れると何が起きるか: 欄と一覧を行き来できず、頼めないか一覧を操れない。欄で打った space・↵ が一覧の止める・地図へ入る
/// 操作になる。クリックした場所とキーの届く場所が食い違い、行をクリックしてから押した space が欄に入る。
extension BoardAutomationTests {
  /// 一覧の行・欄・地の窓の中の点（1200×700 の窓、見本の寸法から）。
  private enum Point {
    static let field = NSPoint(x: 300, y: 669)
    /// 欄の枠の中で入力欄の外（上の余白・❯・「↵ 依頼する」）。
    static let fieldMargins = [
      NSPoint(x: 300, y: 684), NSPoint(x: 35, y: 669), NSPoint(x: 1140, y: 669),
    ]
    static let secondRow = NSPoint(x: 120, y: 536)
    /// 一覧でも欄でもない地（右の欄）。
    static let ground = NSPoint(x: 800, y: 100)
    /// 一覧の行の下の空き。
    static let listGround = NSPoint(x: 120, y: 100)
  }

  func type(_ text: String, to window: NSWindow) {
    for character in text {
      send(Key.a, String(character), to: window)
    }
  }

  /// 欄は一覧の上の 1 段で、欄と行は 1 つの選択を分け合う。ウィジェットは欄から始まり、欄を選んでいる間は行の選択と詳細が無い。
  /// 欄の ↓ で一覧の先頭、先頭の行の ↑ で欄、欄の ↑ で一覧の末尾（巡回）、末尾の行の ↓ で欄（巡回）、欄の esc は ↓ と同じく
  /// 一覧の先頭へ。⇥・⇧⇥ は欄でも一覧でも何もせず、一覧の → で地図へ入り、地図の ← で一覧へ戻る。
  func testArrowsMoveOneSelectionThroughTheFieldAndTheRows() {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    XCTAssertEqual(automation.place, .request, "欄から始まる")
    XCTAssertEqual(automation.list.selectedID, .request)
    XCTAssertNil(automation.selectedAutomation, "欄を選んでいる間はどの行も選ばれず、詳細も無い")

    type("a b", to: window)
    XCTAssertEqual(automation.requestText, "a b", "space は欄の文字になる")
    XCTAssertEqual(
      automation.store.automations, untouched, "space は一覧の止めるにならない")
    send(Key.tab, "\t", to: window)
    XCTAssertEqual(automation.place, .request, "欄の ⇥ は何もしない")

    down(window)
    XCTAssertEqual(automation.place, .list, "欄の ↓ で一覧へ")
    XCTAssertEqual(automation.selectedAutomation?.id, Self.failingBacklog, "一覧の先頭")
    send(Key.tab, "\t", to: window)
    send(Key.tab, "\u{19}", .shift, to: window)
    XCTAssertEqual(automation.place, .list, "一覧の ⇥ / ⇧⇥ は何もしない")
    right(window)
    XCTAssertEqual(automation.place, .map, "一覧の → で地図へ")
    left(window)
    XCTAssertEqual(automation.place, .list, "地図の ← で一覧へ")
    down(window)
    XCTAssertEqual(automation.selectedAutomation?.id, Self.slack, "一覧のキーが効く")

    up(window)
    up(window)
    XCTAssertEqual(automation.place, .request, "先頭の行の ↑ で欄へ")
    up(window)
    XCTAssertEqual(automation.place, .list, "欄の ↑ で一覧へ")
    XCTAssertEqual(automation.selectedAutomation?.id, Self.pausedGmail, "巡回して一覧の末尾")
    down(window)
    XCTAssertEqual(automation.place, .request, "末尾の行の ↓ で巡回して欄へ")

    send(Key.escape, "\u{1B}", to: window)
    XCTAssertEqual(automation.place, .list, "欄の esc で一覧へ")
    XCTAssertEqual(automation.selectedAutomation?.id, Self.failingBacklog, "esc は ↓ と同じく一覧の先頭")
    XCTAssertEqual(automation.requestText, "a b", "打った文字は残る")
  }

  /// 欄へ戻ると、打ってあった文は AppKit の入力欄の既定どおり全文が選ばれる（⌘⇧X の入力欄と同じ）。
  func testReturningToTheFieldSelectsItsText() throws {
    let model = board()
    let window = mount(model)
    type("abc", to: window)
    down(window)
    up(window)

    let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "欄に焦点がある")
    XCTAssertEqual(editor.string, "abc")
    XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 3))
  }

  /// 一覧に居る間に行がすべて消えると欄になり、焦点も欄へ移って続けて打てる。
  func testWhenEveryRowIsGoneTheFieldTakesOver() throws {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    down(window)
    XCTAssertEqual(automation.place, .list, "前提")

    for id in automation.ids { try automation.runner.delete(id) }
    flush(window)
    XCTAssertEqual(automation.place, .request)
    type("a", to: window)
    XCTAssertEqual(automation.requestText, "a")
  }

  /// 地図に居る間に選んでいた自動化がほかの口で消えると、一覧の同じ位置の行へ戻り、焦点も一覧へ戻って続けて打てる。
  func testWhenTheAutomationOnTheMapIsGoneTheListTakesOver() throws {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    down(window)
    right(window)
    XCTAssertEqual(automation.place, .map, "前提")
    let gone = try XCTUnwrap(automation.selectedAutomation?.id)

    try automation.runner.delete(gone)
    flush(window)
    XCTAssertEqual(automation.place, .list)
    let stayed = try XCTUnwrap(automation.selectedAutomation?.id)
    XCTAssertNotEqual(stayed, gone)
    down(window)
    XCTAssertNotEqual(automation.selectedAutomation?.id, stayed, "一覧の ↓ が効く")
    XCTAssertEqual(automation.place, .list)
  }

  /// 欄のクリックで欄、行や一覧の下の空きのクリックで一覧へ移る。右の地のクリックは、欄に居れば欄のまま、自動化を選んで
  /// いれば地図へ入る。直後のキーはそこに届く。
  func testClicksMoveTheFocusAndTheNextKeyArrivesThere() {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    placeOffscreen(window)

    click(Point.field, in: window)
    XCTAssertEqual(automation.place, .request)
    type("b", to: window)
    XCTAssertEqual(automation.requestText, "b")

    click(Point.secondRow, in: window)
    XCTAssertEqual(automation.place, .list)
    XCTAssertEqual(automation.selectedAutomation?.id, Self.slack)
    send(Key.space, " ", to: window)
    XCTAssertEqual(automation.store.automation(Self.slack)?.paused, true, "行のクリックの直後の space は一覧に効く")
    XCTAssertEqual(automation.requestText, "b")

    click(Point.field, in: window)
    click(Point.ground, in: window)
    XCTAssertEqual(automation.place, .request, "地は選んでいる場所")
    type("c", to: window)
    XCTAssertEqual(automation.requestText, "c", "欄へ戻ると全文が選ばれているので、打てば置き換わる")

    send(Key.escape, "\u{1B}", to: window)
    let chosen = automation.selectedAutomation?.id
    click(Point.ground, in: window)
    XCTAssertEqual(automation.place, .map, "自動化を選んでいれば、地図の地は地図")
    let before = automation.selectedMapStop
    down(window)
    XCTAssertNotEqual(automation.selectedMapStop, before, "地のクリックの直後の ↓ は地図に効く")
    XCTAssertEqual(automation.selectedAutomation?.id, chosen, "一覧の選択は動かない")

    click(Point.field, in: window)
    click(Point.listGround, in: window)
    XCTAssertEqual(automation.place, .list, "一覧の下の空きは一覧")
    XCTAssertEqual(automation.selectedAutomation?.id, Self.failingBacklog, "欄から来たなら一覧の先頭")
  }

  /// 欄の枠のどこを押しても欄（入力欄の字の高さの外の余白・❯・「↵ 依頼する」も）。
  func testClickingAnywhereInTheFieldsFrameMovesTheFocusToTheField() {
    let model = board()
    let automation = model.automation
    let window = mount(model)
    placeOffscreen(window)

    for point in Point.fieldMargins {
      send(Key.escape, "\u{1B}", to: window)
      XCTAssertEqual(automation.place, .list)
      click(point, in: window)
      XCTAssertEqual(automation.place, .request, "\(point)")
      type("x", to: window)
      XCTAssertEqual(automation.requestText, "x", "\(point) の直後の文字は欄に入る")
    }
  }
}
