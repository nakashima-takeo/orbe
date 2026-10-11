import AppKit
import XCTest

@testable import Orbe

/// 自動追加の部品の中の焦点——依頼の欄と一覧の行き来。本物の `BoardView` を実窓に載せ、実 `NSEvent` のキーとクリックを届ける。
///
/// 壊れると何が起きるか: 欄と一覧を行き来できず、頼めないか一覧を操れない。欄で打った space・↵ が一覧の止める・今すぐ実行になる。クリックした場所と
/// キーの届く場所が食い違い、行をクリックしてから押した space が欄に入る。
extension BoardIntakeTests {
  /// 一覧の行・欄・地の窓の中の点（1200×700 の窓、見本の寸法から）。
  private enum Point {
    static let field = NSPoint(x: 300, y: 619)
    /// 欄の枠の中で入力欄の外（上の余白・❯・「↵ 依頼」）。
    static let fieldMargins = [
      NSPoint(x: 300, y: 632), NSPoint(x: 66, y: 613), NSPoint(x: 1120, y: 613),
    ]
    static let secondRow = NSPoint(x: 120, y: 485)
    static let ground = NSPoint(x: 120, y: 100)
  }

  func type(_ text: String, to window: NSWindow) {
    for character in text {
      press(Key.a, String(character), to: window)
    }
  }

  /// 窓の点を押して離す。非アクティブなテストの窓では最初のクリックが窓の有効化に使われて SwiftUI のジェスチャまで届かない
  /// ので、押している間だけどのビューも最初のクリックを受ける形にする（実機では窓が前面にあり、クリックがそのまま届く）。
  /// 離す方は先にキューへ入れておく——入力欄の文字の面が押下を受けると、離すまでキューを待つ追跡に入る。
  func click(_ point: NSPoint, in window: NSWindow) {
    let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:)))!
    let always: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
    let original = method_setImplementation(method, imp_implementationWithBlock(always))
    defer { method_setImplementation(method, original) }
    let make = { (type: NSEvent.EventType) in
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }
    NSApp.postEvent(make(.leftMouseUp), atStart: false)
    NSApp.sendEvent(make(.leftMouseDown))
    pump(0.05)
    if let pending = NSApp.nextEvent(
      matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    {
      NSApp.sendEvent(pending)
    }
    pump(0.3)
  }

  /// 欄は一覧の上の 1 段で、欄と行は 1 つの選択を分け合う。部品は欄から始まり、欄を選んでいる間は行の選択と詳細が無い。
  /// 欄の ↓ で一覧の先頭、先頭の行の ↑ で欄、欄の ↑ で一覧の末尾（巡回）、末尾の行の ↓ で欄（巡回）、欄の esc は ↓ と同じく
  /// 一覧の先頭へ。⇥ は欄でも一覧でも何もしない。
  func testArrowsMoveOneSelectionThroughTheFieldAndTheRows() {
    let model = board()
    let intake = model.intake
    let window = mount(model)
    XCTAssertEqual(intake.place, .request, "欄から始まる")
    XCTAssertEqual(intake.list.selectedID, .request)
    XCTAssertNil(intake.selected, "欄を選んでいる間はどの行も選ばれず、詳細も無い")

    type("a b", to: window)
    XCTAssertEqual(intake.requestText, "a b", "space は欄の文字になる")
    XCTAssertEqual(intake.store.intakes, DesignSceneFixtures.boardIntakes(), "space は一覧の止めるにならない")
    press(Key.tab, "\t", to: window)
    XCTAssertEqual(intake.place, .request, "欄の ⇥ は何もしない")

    down(window)
    XCTAssertEqual(intake.place, .list, "欄の ↓ で一覧へ")
    XCTAssertEqual(intake.selected?.id, Self.failingBacklog, "一覧の先頭")
    press(Key.tab, "\t", to: window)
    XCTAssertEqual(intake.place, .list, "一覧の ⇥ は何もしない")
    down(window)
    XCTAssertEqual(intake.selected?.id, Self.slack, "一覧のキーが効く")

    up(window)
    up(window)
    XCTAssertEqual(intake.place, .request, "先頭の行の ↑ で欄へ")
    up(window)
    XCTAssertEqual(intake.place, .list, "欄の ↑ で一覧へ")
    XCTAssertEqual(intake.selected?.id, Self.pausedGmail, "巡回して一覧の末尾")
    down(window)
    XCTAssertEqual(intake.place, .request, "末尾の行の ↓ で巡回して欄へ")

    press(Key.escape, "\u{1B}", to: window)
    XCTAssertEqual(intake.place, .list, "欄の esc で一覧へ")
    XCTAssertEqual(intake.selected?.id, Self.failingBacklog, "esc は ↓ と同じく一覧の先頭")
    XCTAssertEqual(intake.requestText, "a b", "打った文字は残る")
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

  /// 自動追加が 0 件なら、欄の ↑↓ は何もしない（移る行が無い）。
  func testWithNoAutoAddsTheFieldIsTheOnlyStop() {
    let model = BoardModel(
      intake: BoardIntakeModel(
        runner: DesignSceneFixtures.intakeRunner(DesignSceneFixtures.intakeEmptyFile())),
      parts: [.intake])
    let intake = model.intake
    let window = mount(model)
    XCTAssertEqual(intake.place, .request)

    down(window)
    XCTAssertEqual(intake.place, .request, "欄の ↓ は何もしない")
    up(window)
    XCTAssertEqual(intake.place, .request, "欄の ↑ は何もしない")
    XCTAssertEqual(intake.hints.map(\.label), [.boardAskHint], "移る先が無いので ↓ の案内を出さない")
  }

  /// 一覧に居る間に行がすべて消えると欄になり、焦点も欄へ移って続けて打てる。
  func testWhenEveryRowIsGoneTheFieldTakesOver() throws {
    let model = board()
    let intake = model.intake
    let window = mount(model)
    down(window)
    XCTAssertEqual(intake.place, .list, "前提")

    for id in intake.ids { try intake.runner.delete(id) }
    flush(window)
    XCTAssertEqual(intake.place, .request)
    type("a", to: window)
    XCTAssertEqual(intake.requestText, "a")
  }

  /// 欄のクリックで欄、行のクリックで一覧、地のクリックで最後に居た場所へ移り、直後のキーがそこに届く。
  func testClicksMoveTheFocusAndTheNextKeyArrivesThere() {
    let model = board()
    let intake = model.intake
    let window = mount(model)

    click(Point.field, in: window)
    XCTAssertEqual(intake.place, .request)
    type("b", to: window)
    XCTAssertEqual(intake.requestText, "b")

    click(Point.secondRow, in: window)
    XCTAssertEqual(intake.place, .list)
    XCTAssertEqual(intake.selected?.id, Self.slack)
    press(Key.space, " ", to: window)
    XCTAssertEqual(intake.store.intake(Self.slack)?.paused, true, "行のクリックの直後の space は一覧に効く")
    XCTAssertEqual(intake.requestText, "b")

    click(Point.field, in: window)
    click(Point.ground, in: window)
    XCTAssertEqual(intake.place, .request, "地は選んでいる場所")
    type("c", to: window)
    XCTAssertEqual(intake.requestText, "c", "欄へ戻ると全文が選ばれているので、打てば置き換わる")

    press(Key.escape, "\u{1B}", to: window)
    click(Point.ground, in: window)
    XCTAssertEqual(intake.place, .list)
    let before = intake.selected?.id
    down(window)
    XCTAssertNotEqual(intake.selected?.id, before, "地のクリックの直後の ↓ は一覧に効く")
  }

  /// 欄の枠のどこを押しても欄（入力欄の字の高さの外の余白・❯・「↵ 依頼」も）。
  func testClickingAnywhereInTheFieldsFrameMovesTheFocusToTheField() {
    let model = board()
    let intake = model.intake
    let window = mount(model)

    for point in Point.fieldMargins {
      press(Key.escape, "\u{1B}", to: window)
      XCTAssertEqual(intake.place, .list)
      click(point, in: window)
      XCTAssertEqual(intake.place, .request, "\(point)")
      type("x", to: window)
      XCTAssertEqual(intake.requestText, "x", "\(point) の直後の文字は欄に入る")
    }
  }
}
