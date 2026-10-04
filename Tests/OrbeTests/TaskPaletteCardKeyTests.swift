import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 本物の `TaskPaletteCard` を実 `NSWindow` に載せ、実 `NSEvent` のキーを届けて、焦点の行き先（入力欄 /
/// 詳細の項目 / 詳細の編集欄）ごとにキーが意図した操作になることを固定する。agent の変更をカードが
/// 付け直しへ届ける配線も、キーの当たり先として測る。
///
/// 壊れると何が起きるか: 入力欄に文字があるのに space がタスクを完了にする、入力を消そうと ⌘⌫ を押し続けた
/// リピートで次のタスクまで消える。→ で詳細に入れない、詳細で打った文字が編集欄に届かず一覧の入力に入る、
/// ⇥ で焦点がカードの外へ逃げて以後のキーが効かない。どれもモデル単体では再現せず、実際に描いて
/// キーを届けないと分からない。
@MainActor
final class TaskPaletteCardKeyTests: PaletteCardWindowTestCase {
  enum Key {
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let enter: UInt16 = 36
    static let escape: UInt16 = 53
    static let tab: UInt16 = 48
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
  }

  /// 実機の矢印キーは numericPad と function の修飾を伴って届く。
  let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]

  func model() -> TaskPaletteModel { TaskPaletteSamples.threeTodos() }

  func mount(_ model: TaskPaletteModel) -> NSWindow {
    NSApplication.shared.setActivationPolicy(.accessory)
    let window = KeyWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 640),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = FirstMouseHost(
      rootView: TaskPaletteCard(model: model, detailWidth: 340)
        .frame(width: 960, height: 600)
        .environment(\.localization, LocalizationStore(language: .ja)))
    window.makeKeyAndOrderFront(nil)
    held.append(window)
    pump(0.4)
    return window
  }

  private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
  }

  /// 非アクティブなテストの窓では、最初のクリックが窓の有効化に使われて SwiftUI のジェスチャまで届かない。
  /// 実機では窓が前面にあるので、クリックがそのまま届く形に揃える。
  private final class FirstMouseHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  }

  private var held: [NSWindow] = []

  override func tearDown() {
    held.forEach { $0.orderOut(nil) }
    held.removeAll()
    super.tearDown()
  }

  func press(
    _ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [],
    repeating: Bool = false, to window: NSWindow
  ) {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: repeating, keyCode: keyCode)
    else { return XCTFail("キーイベントを作れない") }
    NSApp.sendEvent(event)
    pump(0.15)
  }

  /// 実アプリと同じく、キューから取り出してから配る（`NSApp.currentEvent` がそのキーを指す）。
  /// 変換中かの判定は、届いたキーの窓をここから引く。
  private func pressThroughTheEventQueue(
    _ keyCode: UInt16, _ characters: String, to window: NSWindow
  ) {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode)
    else { return XCTFail("キーイベントを作れない") }
    NSApp.postEvent(event, atStart: true)
    guard
      let dequeued = NSApp.nextEvent(
        matching: .keyDown, until: Date().addingTimeInterval(1), inMode: .default, dequeue: true)
    else { return XCTFail("キーイベントがキューから取れない") }
    NSApp.sendEvent(dequeued)
    pump(0.15)
  }

  /// ヘッダーの入力欄（カード左上の「❯」の右）を実 NSEvent のマウスでクリックする。窓はカードの
  /// 大きさに揃うので、窓座標（原点は左下）でヘッダーの縦中央を叩く。離す方は先にキューへ入れておく
  /// ——入力欄の文字の面が押下を受けると、離すまでキューを待つ追跡に入り、後から送ると戻ってこない。
  func click(atFieldOf window: NSWindow) throws {
    let content = try XCTUnwrap(window.contentView)
    let point = NSPoint(x: 120, y: content.bounds.height - 28)
    let make = { (type: NSEvent.EventType) in
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
    }
    let down = try XCTUnwrap(make(.leftMouseDown))
    let up = try XCTUnwrap(make(.leftMouseUp))
    NSApp.postEvent(up, atStart: false)
    NSApp.sendEvent(down)
    pump(0.05)
    if let pending = NSApp.nextEvent(
      matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    {
      NSApp.sendEvent(pending)
    }
    pump(0.3)
  }

  func arrow(_ keyCode: UInt16, _ extra: NSEvent.ModifierFlags = [], to window: NSWindow) {
    let character: NSEvent.SpecialKey =
      switch keyCode {
      case Key.left: .leftArrow
      case Key.right: .rightArrow
      case Key.up: .upArrow
      default: .downArrow
      }
    press(
      keyCode, String(UnicodeScalar(character.rawValue)!), arrowFlags.union(extra), to: window)
  }

  func type(_ text: String, into window: NSWindow) {
    for character in text { press(0, String(character), to: window) }
  }

  func status(_ model: TaskPaletteModel, _ id: Int) -> TaskItem.Status? {
    model.store.tasks.first { $0.id == id }?.status
  }

  // MARK: - 入力欄（一覧）

  func testSpaceCompletesTheSelectedTaskOnlyWhileTheFieldIsEmpty() {
    let model = model()
    let window = mount(model)

    press(Key.space, " ", to: window)
    XCTAssertEqual(status(model, 1), .done, "空の入力欄の space は選んだタスクを完了にする")

    type("b", into: window)
    press(Key.space, " ", to: window)
    XCTAssertEqual(model.query, "b ", "文字があるときの space は空白を打つ")
    XCTAssertEqual(status(model, 2), .todo)
  }

  func testSpaceWithCapsLockOnStillCompletesTheSelectedTask() {
    let model = model()
    let window = mount(model)

    press(Key.space, " ", .capsLock, to: window)

    XCTAssertEqual(status(model, 1), .done)
  }

  func testSpaceWhileComposingGoesToTheInputMethodInsteadOfCompleting() throws {
    let model = model()
    let window = mount(model)
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "前提: 入力欄の field editor")
    editor.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText(), "前提: 変換中")

    pressThroughTheEventQueue(Key.space, " ", to: window)

    XCTAssertEqual(status(model, 1), .todo, "変換中の space はタスクを完了にしない")
  }

  func testEnterCompletesTheSelectedTaskAndAddsFromTheAddRow() throws {
    let model = model()
    let window = mount(model)

    press(Key.enter, "\r", to: window)
    XCTAssertEqual(status(model, 1), .done)

    type("新しい", into: window)
    press(Key.enter, "\r", to: window)
    XCTAssertEqual(model.store.tasks.last?.title, "新しい")
    XCTAssertEqual(model.query, "")
  }

  func testCommandBackspaceDeletesOneTaskEvenWhenHeldDown() {
    let model = model()
    let window = mount(model)

    press(Key.delete, "\u{7F}", .command, to: window)
    press(Key.delete, "\u{7F}", .command, repeating: true, to: window)
    press(Key.delete, "\u{7F}", .command, repeating: true, to: window)

    XCTAssertEqual(model.store.tasks.map(\.id), [2, 3], "消えるのは押した 1 件だけ")
  }

  func testSpaceHeldDownCompletesOneTaskAndTypesNoSpace() {
    let model = model()
    let window = mount(model)

    press(Key.space, " ", to: window)
    press(Key.space, " ", repeating: true, to: window)
    press(Key.space, " ", repeating: true, to: window)

    XCTAssertEqual(model.store.tasks.map(\.status), [.done, .todo, .todo], "完了は押した 1 件だけ")
    XCTAssertEqual(model.query, "", "リピートは入力欄に空白を入れない")
  }

  func testCommandBackspaceWithTextEditsTheFieldInsteadOfDeleting() {
    let model = model()
    let window = mount(model)
    type("a", into: window)
    arrow(Key.down, to: window)
    XCTAssertEqual(model.selectedID, .task(1), "前提: 一致したタスクを選んだ")

    press(Key.delete, "\u{7F}", .command, to: window)

    XCTAssertEqual(model.store.tasks.count, 3, "文字があるときはタスクを消さない")
    XCTAssertEqual(model.query, "", "入力欄の文字を行頭まで消す")
  }

  func testOptionArrowsReorderAndCommandArrowsJump() {
    let model = model()
    let window = mount(model)

    arrow(Key.down, .command, to: window)
    XCTAssertEqual(model.selectedID, .task(3), "⌘↓ で末尾へ")

    arrow(Key.up, .option, to: window)
    XCTAssertEqual(model.store.tasks.map(\.id), [1, 3, 2], "⌥↑ で前のタスクの前へ")
    XCTAssertEqual(model.selectedID, .task(3))
  }

  func testTabSwitchesScopeAndShiftTabSwitchesTabWhileTheFieldKeepsTheKeys() {
    let model = model()
    let window = mount(model)

    press(Key.tab, "\t", to: window)
    XCTAssertEqual(model.scope, .opened)

    press(Key.tab, "\u{19}", .shift, to: window)
    XCTAssertEqual(model.tab, .github)

    press(Key.tab, "\u{19}", .shift, to: window)
    type("x", into: window)
    XCTAssertEqual(model.tab, .tasks)
    XCTAssertEqual(model.query, "x", "焦点は入力欄に残り、続けて打てる")
  }

  func testEscapeInTheListClosesTheScreen() {
    let model = model()
    var dismissed = false
    model.onDismiss = { dismissed = true }
    let window = mount(model)

    press(Key.escape, "\u{1B}", to: window)

    XCTAssertTrue(dismissed)
  }

  /// agent の変更（ストアの直接の変異）は、カードが付け直しへ届ける。選んでいたタスクが消えたら、
  /// 直後の space は同じ位置に来た行に効き、消えたタスクの ID には向かわない。
  func testAgentDeletingTheSelectedTaskMovesTheSelectionBeforeTheNextKey() throws {
    let model = model()
    let window = mount(model)
    arrow(Key.down, to: window)
    XCTAssertEqual(model.selectedID, .task(2), "前提")

    try model.store.delete(2)
    flush(window)
    press(Key.space, " ", to: window)

    XCTAssertEqual(status(model, 3), .done, "同じ位置に来た c を完了にする")
  }
}
