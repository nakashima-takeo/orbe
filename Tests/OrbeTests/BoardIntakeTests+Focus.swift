import AppKit
import XCTest

@testable import Orbe

/// 自動追加の部品の中の焦点——依頼の欄と一覧の行き来。本物の `BoardView` を実窓に載せ、実 `NSEvent` のキーとクリックを届ける。
///
/// 壊れると何が起きるか: ⇥ で欄へ移れず頼めない。欄で打った space・↵ が一覧の止める・今すぐ実行になる。クリックした場所と
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

  /// 最初は一覧。⇥ で欄へ移って文字が入り、⇥・↓・esc で一覧へ戻ってキーが一覧に効く。
  func testTabMovesBetweenTheFieldAndTheList() {
    let model = board()
    let intake = model.intake
    let window = mount(model)
    XCTAssertEqual(intake.place, .list)

    press(Key.tab, "\t", to: window)
    XCTAssertEqual(intake.place, .request)
    type("a b", to: window)
    XCTAssertEqual(intake.request.text, "a b", "space は欄の文字になる")
    XCTAssertEqual(intake.store.intakes, DesignSceneFixtures.boardIntakes(), "space は一覧の止めるにならない")

    press(Key.tab, "\t", to: window)
    XCTAssertEqual(intake.place, .list)
    down(window)
    XCTAssertEqual(intake.selected?.id, Self.slack, "一覧のキーが効く")

    press(Key.tab, "\t", to: window)
    down(window)
    XCTAssertEqual(intake.place, .list, "欄の ↓ で一覧へ")
    XCTAssertEqual(intake.selected?.id, Self.slack, "移るだけで選択は動かない")

    press(Key.tab, "\t", to: window)
    press(Key.escape, "\u{1B}", to: window)
    XCTAssertEqual(intake.place, .list, "欄の esc で一覧へ")
    down(window)
    XCTAssertEqual(intake.selected?.id, Self.github)
    XCTAssertEqual(intake.request.text, "a b", "打った文字は残る")
  }

  /// 欄のクリックで欄、行のクリックで一覧、地のクリックで最後に居た場所へ移り、直後のキーがそこに届く。
  func testClicksMoveTheFocusAndTheNextKeyArrivesThere() {
    let model = board()
    let intake = model.intake
    let window = mount(model)

    click(Point.field, in: window)
    XCTAssertEqual(intake.place, .request)
    type("b", to: window)
    XCTAssertEqual(intake.request.text, "b")

    click(Point.secondRow, in: window)
    XCTAssertEqual(intake.place, .list)
    XCTAssertEqual(intake.selected?.id, Self.slack)
    press(Key.space, " ", to: window)
    XCTAssertEqual(intake.store.intake(Self.slack)?.paused, true, "行のクリックの直後の space は一覧に効く")
    XCTAssertEqual(intake.request.text, "b")

    click(Point.field, in: window)
    click(Point.ground, in: window)
    XCTAssertEqual(intake.place, .request, "地は最後に居た場所")
    type("c", to: window)
    XCTAssertEqual(intake.request.text, "bc")

    press(Key.tab, "\t", to: window)
    click(Point.ground, in: window)
    XCTAssertEqual(intake.place, .list)
    down(window)
    XCTAssertNotEqual(intake.selected?.id, Self.slack, "地のクリックの直後の ↓ は一覧に効く")
  }
}
