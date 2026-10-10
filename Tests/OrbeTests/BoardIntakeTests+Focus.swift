import AppKit
import XCTest

@testable import Orbe

/// 自動追加の部品の中の焦点——依頼の欄と一覧の行き来。本物の `BoardView` を実窓に載せ、実 `NSEvent` のキーとクリックを届ける。
///
/// 壊れると何が起きるか: ↑ で欄へ移れず頼めない。欄で打った space・↵ が一覧の止める・今すぐ実行になる。クリックした場所と
/// キーの届く場所が食い違い、行をクリックしてから押した space が欄に入る。
extension BoardIntakeTests {
  /// 一覧の行・欄・地の窓の中の点（1200×700 の窓、見本の寸法から）。
  private enum Point {
    static let field = NSPoint(x: 300, y: 619)
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

  /// 欄は一覧の上の 1 段。先頭の行の ↑ で欄へ移って文字が入り、欄の ↓ で一覧の先頭、欄の ↑ で一覧の末尾（巡回）、末尾の行の
  /// ↓ で欄（巡回）、欄の esc で選択をそのままに一覧へ戻る。⇥ は欄でも一覧でも何もしない。
  func testArrowsMoveBetweenTheFieldAboveAndTheList() {
    let model = board()
    let intake = model.intake
    let window = mount(model)
    XCTAssertEqual(intake.place, .list)
    XCTAssertEqual(intake.selected?.id, Self.failingBacklog, "前提: 先頭の行")

    press(Key.tab, "\t", to: window)
    XCTAssertEqual(intake.place, .list, "一覧の ⇥ は何もしない")

    up(window)
    XCTAssertEqual(intake.place, .request, "先頭の行の ↑ で欄へ")
    type("a b", to: window)
    XCTAssertEqual(intake.requestText, "a b", "space は欄の文字になる")
    XCTAssertEqual(intake.store.intakes, DesignSceneFixtures.boardIntakes(), "space は一覧の止めるにならない")
    press(Key.tab, "\t", to: window)
    XCTAssertEqual(intake.place, .request, "欄の ⇥ は何もしない")

    down(window)
    XCTAssertEqual(intake.place, .list, "欄の ↓ で一覧へ")
    XCTAssertEqual(intake.selected?.id, Self.failingBacklog, "一覧の先頭")
    down(window)
    XCTAssertEqual(intake.selected?.id, Self.slack, "一覧のキーが効く")

    up(window)
    up(window)
    up(window)
    XCTAssertEqual(intake.place, .list, "欄の ↑ で一覧へ")
    XCTAssertEqual(intake.selected?.id, Self.pausedGmail, "巡回して一覧の末尾")
    down(window)
    XCTAssertEqual(intake.place, .request, "末尾の行の ↓ で巡回して欄へ")

    press(Key.escape, "\u{1B}", to: window)
    XCTAssertEqual(intake.place, .list, "欄の esc で一覧へ")
    XCTAssertEqual(intake.selected?.id, Self.pausedGmail, "esc は選択を動かさない")
    XCTAssertEqual(intake.requestText, "a b", "打った文字は残る")
  }

  /// 自動追加が 0 件なら、欄の ↑↓ は何もしない（移る行が無い）。0 件の一覧の ↑↓ は欄へ移る。
  func testWithNoAutoAddsTheFieldArrowsStay() {
    let model = BoardModel(
      intake: BoardIntakeModel(
        runner: DesignSceneFixtures.intakeRunner(DesignSceneFixtures.intakeEmptyFile())))
    let intake = model.intake
    let window = mount(model)

    down(window)
    XCTAssertEqual(intake.place, .request)
    down(window)
    XCTAssertEqual(intake.place, .request, "欄の ↓ は何もしない")
    up(window)
    XCTAssertEqual(intake.place, .request, "欄の ↑ は何もしない")
    XCTAssertEqual(intake.hints.map(\.label), [.boardAskHint], "移る先が無いので ↓ の案内を出さない")
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
    XCTAssertEqual(intake.place, .request, "地は最後に居た場所")
    type("c", to: window)
    XCTAssertEqual(intake.requestText, "bc")

    press(Key.escape, "\u{1B}", to: window)
    click(Point.ground, in: window)
    XCTAssertEqual(intake.place, .list)
    down(window)
    XCTAssertNotEqual(intake.selected?.id, Self.slack, "地のクリックの直後の ↓ は一覧に効く")
  }
}
