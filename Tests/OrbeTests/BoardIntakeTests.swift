import AppKit
import XCTest

@testable import Orbe

/// ボードの自動追加の部品——一覧の並びと、選んだ自動追加へのキー。本物の `BoardView`（中身は SwiftUI）を実窓に載せ、実
/// `NSEvent` のキーを届ける。走らせ役は取得が終わらない偽物で、本物の claude は起きない。
///
/// 壊れると何が起きるか: 前回が失敗した自動追加が一覧の上に来ず、壊れた取得に気づけない。走り出すたびに行が跳ね、↵ を押した
/// 直後に選択の位置が狂う。⌘⌫ を押し続けたリピートで次の自動追加まで消える（戻せない）。space のリピートで止める ⇄ 再開が
/// 往復し、どちらになったか分からない。⌘↵ で今すぐ実行が走る。AI や ⌘⇧X が選んでいる自動追加を消すと選択が宙に浮き、
/// 詳細が消えてキーが効かなくなる。
@MainActor
final class BoardIntakeTests: PaletteCardWindowTestCase {
  private enum Key {
    static let x: UInt16 = 7
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let enter: UInt16 = 36
    static let down: UInt16 = 125
  }

  // 見本『Home』の 4 件（DesignSceneFixtures+Board）。
  private static let slack = 1
  private static let github = 2
  private static let failingBacklog = 3
  private static let pausedGmail = 4

  private var held: [NSWindow] = []

  override func tearDown() {
    held.forEach { $0.orderOut(nil) }
    held.removeAll()
    super.tearDown()
  }

  private func board() -> BoardModel {
    BoardModel(
      intake: BoardIntakeModel(
        runner: DesignSceneFixtures.intakeRunner(DesignSceneFixtures.boardIntakeFile())))
  }

  /// ボードを実窓に載せ、ボードを選んだときと同じ当て直し（`focus()`）で焦点を中へ入れる。
  private func mount(_ model: BoardModel) -> NSWindow {
    NSApplication.shared.setActivationPolicy(.accessory)
    let window = KeyDeliveryWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 700),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = BoardView(
      model: model, translucency: ChromeTranslucency(),
      localization: LocalizationStore(language: .ja), fontResolver: ChromeFontResolver())
    window.makeKeyAndOrderFront(nil)
    held.append(window)
    pump(0.4)
    model.focus()
    flush(window)
    return window
  }

  /// 実アプリと同じく、キューから取り出してから配る（SwiftUI はキーリピートかをそのキーから読む）。
  private func press(
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
    NSApp.postEvent(event, atStart: true)
    guard
      let dequeued = NSApp.nextEvent(
        matching: .keyDown, until: Date().addingTimeInterval(1), inMode: .default, dequeue: true)
    else { return XCTFail("キーイベントがキューから取れない") }
    NSApp.sendEvent(dequeued)
    pump(0.15)
  }

  /// 実機の矢印キーは numericPad と function の修飾を伴って届く。
  private func down(_ window: NSWindow) {
    press(Key.down, "\u{F701}", [.numericPad, .function], to: window)
  }

  // MARK: - 並び

  func testRowsAreFailingThenActiveThenPausedAndRunningDoesNotReorderThem() throws {
    let intake = board().intake
    XCTAssertEqual(
      intake.ids, [Self.failingBacklog, Self.slack, Self.github, Self.pausedGmail],
      "前回が失敗 → それ以外 → 止めている。群の中は ID 順")

    try intake.runner.runNow(Self.github)
    XCTAssertTrue(intake.runner.isRunning(Self.github), "前提: 走っている")

    XCTAssertEqual(
      intake.ids, [Self.failingBacklog, Self.slack, Self.github, Self.pausedGmail],
      "走り出しても行は動かない")
  }

  // MARK: - キー

  /// ↓ で選び、space で止める ⇄ 再開（沈んでも選択は付いていく）、↵ で今すぐ実行、⌘⌫ で消して同じ位置の行を選ぶ。
  func testKeysActOnTheSelectedIntake() {
    let model = board()
    let intake = model.intake
    let window = mount(model)

    down(window)
    XCTAssertEqual(intake.selected?.id, Self.slack)

    press(Key.space, " ", to: window)
    XCTAssertEqual(intake.store.intake(Self.slack)?.paused, true)
    XCTAssertEqual(intake.selected?.id, Self.slack, "末尾へ沈んでも選択は同じ自動追加")
    press(Key.space, " ", to: window)
    XCTAssertEqual(intake.store.intake(Self.slack)?.paused, false)

    press(Key.enter, "\r", to: window)
    XCTAssertTrue(intake.runner.isRunning(Self.slack))

    down(window)
    XCTAssertEqual(intake.selected?.id, Self.github, "前提")
    press(Key.delete, "\u{7F}", .command, to: window)
    XCTAssertNil(intake.store.intake(Self.github))
    XCTAssertEqual(intake.selected?.id, Self.pausedGmail, "同じ位置の行")
  }

  /// space・↵・⌘⌫ は押し続けても 1 回だけ効く。
  func testHeldKeysActOnce() {
    let model = board()
    let intake = model.intake
    let window = mount(model)
    down(window)

    press(Key.space, " ", to: window)
    press(Key.space, " ", repeating: true, to: window)
    XCTAssertEqual(intake.store.intake(Self.slack)?.paused, true, "止める ⇄ 再開は 1 回だけ（往復しない）")

    press(Key.enter, "\r", to: window)
    press(Key.enter, "\r", repeating: true, to: window)
    XCTAssertTrue(intake.runner.isRunning(Self.slack))
    XCTAssertNil(intake.refusal, "リピートで「実行中のため今すぐ実行できません」の赤を出さない")

    press(Key.delete, "\u{7F}", .command, to: window)
    press(Key.delete, "\u{7F}", .command, repeating: true, to: window)
    press(Key.delete, "\u{7F}", .command, repeating: true, to: window)
    XCTAssertEqual(
      intake.store.intakes.map(\.id), [Self.github, Self.failingBacklog, Self.pausedGmail],
      "消えるのは 1 件だけ")
  }

  /// 今すぐ実行は修飾なしの ↵ だけ。⌘↵・⇧↵・文字キーは何も起こさない。
  func testModifiedEnterAndLettersDoNothing() {
    let model = board()
    let intake = model.intake
    let window = mount(model)

    press(Key.enter, "\r", .command, to: window)
    press(Key.enter, "\r", .shift, to: window)
    press(Key.x, "x", to: window)

    XCTAssertFalse(intake.store.intakes.contains { intake.runner.isRunning($0.id) }, "どれも走らない")
    XCTAssertEqual(intake.store.intakes, DesignSceneFixtures.boardIntakes(), "どれも変わらない")
    XCTAssertEqual(intake.selected?.id, Self.failingBacklog, "選択も動かない")
  }

  // MARK: - 追従

  /// ほかの口（AI・⌘⇧X）が選んでいる自動追加を消すと、ボードは同じ位置の行を選び、キーはその行に効く。
  func testDeletionElsewhereMovesTheSelectionToTheSamePosition() throws {
    let model = board()
    let intake = model.intake
    let window = mount(model)
    down(window)
    XCTAssertEqual(intake.selected?.id, Self.slack, "前提")

    try intake.runner.delete(Self.slack)
    flush(window)

    XCTAssertEqual(intake.selected?.id, Self.github)
    press(Key.space, " ", to: window)
    XCTAssertEqual(intake.store.intake(Self.github)?.paused, true)
  }
}
