import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 本物の `TaskPaletteCard` を実 `NSWindow` に載せ、実 `NSEvent` のキーを届けて、焦点の行き先（入力欄 /
/// 右の欄の項目 / 右の欄の編集欄）ごとにキーが意図した操作になることを固定する。agent の変更をカードが
/// 付け直しへ届ける配線も、キーの当たり先として測る。
///
/// 壊れると何が起きるか: 入力欄に文字があるのに space がタスクを完了にする、入力を消そうと ⌘⌫ を押し続けた
/// リピートで次のタスクまで消える。→ で右の欄に入れない、右の欄で打った文字が編集欄に届かず一覧の入力に入る、
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

  func mount(
    _ model: TaskPaletteModel, width: CGFloat = 960, detailWidth: CGFloat = 340
  ) -> NSWindow {
    NSApplication.shared.setActivationPolicy(.accessory)
    let window = KeyDeliveryWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: width + 40, height: 640),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = FirstMouseHost(
      rootView: TaskPaletteCard(model: model, detailWidth: detailWidth)
        .frame(width: width, height: 600)
        .environment(\.localization, LocalizationStore(language: .ja)))
    window.makeKeyAndOrderFront(nil)
    held.append(window)
    pump(0.4)
    return window
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

  /// ヘッダーの入力欄（カード左上の「❯」の右）をクリックする。窓はカードの大きさに揃うので、窓座標
  /// （原点は左下）でヘッダーの縦中央を叩く。
  func click(atFieldOf window: NSWindow) throws {
    let content = try XCTUnwrap(window.contentView)
    try click(NSPoint(x: 120, y: content.bounds.height - 28), in: window)
  }

  /// 窓座標（原点は左下）の 1 点を実 NSEvent のマウスでクリックする。離す方は先にキューへ入れておく——入力欄の
  /// 文字の面が押下を受けると、離すまでキューを待つ追跡に入り、後から送ると戻ってこない。
  func click(_ point: NSPoint, in window: NSWindow) throws {
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

  func arrow(
    _ keyCode: UInt16, _ extra: NSEvent.ModifierFlags = [], repeating: Bool = false,
    to window: NSWindow
  ) {
    let character: NSEvent.SpecialKey =
      switch keyCode {
      case Key.left: .leftArrow
      case Key.right: .rightArrow
      case Key.up: .upArrow
      default: .downArrow
      }
    send(
      keyCode, String(UnicodeScalar(character.rawValue)!), arrowFlags.union(extra),
      repeating: repeating, to: window)
  }

  func type(_ text: String, into window: NSWindow) {
    for character in text { send(0, String(character), to: window) }
  }

  func status(_ model: TaskPaletteModel, _ id: Int) -> TaskItem.Status? {
    model.store.tasks.first { $0.id == id }?.status
  }

  // MARK: - 入力欄（一覧）

  func testSpaceCompletesTheSelectedTaskOnlyWhileTheFieldIsEmpty() {
    let model = model()
    let window = mount(model)

    send(Key.space, " ", to: window)
    XCTAssertEqual(status(model, 3), .done, "空の入力欄の space は選んだタスクを完了にする")

    type("b", into: window)
    send(Key.space, " ", to: window)
    XCTAssertEqual(model.query, "b ", "文字があるときの space は空白を打つ")
    XCTAssertEqual(status(model, 2), .todo)
  }

  func testSpaceWithCapsLockOnStillCompletesTheSelectedTask() {
    let model = model()
    let window = mount(model)

    send(Key.space, " ", .capsLock, to: window)

    XCTAssertEqual(status(model, 3), .done)
  }

  func testEnterCompletesTheSelectedTaskAndAddsFromTheAddRow() throws {
    let model = model()
    let window = mount(model)

    send(Key.enter, "\r", to: window)
    XCTAssertEqual(status(model, 3), .done)

    type("新しい", into: window)
    send(Key.enter, "\r", to: window)
    XCTAssertTrue(model.store.tasks.contains { $0.title == "新しい" })
    XCTAssertEqual(model.query, "")
  }

  /// 入力欄の ⌘↵ は onSubmit（↵ = 追加）へ流れず、打った文を agent に任せる。タスクの行を選んで ⌘↵ なら、そのタスクの
  /// agent を開く。
  func testCommandEnterInTheFieldHandsTheTextOverAndOnARowOpensTheAgent() {
    let model = model()
    var asks: [String] = []
    model.onAskSecretary = {
      asks.append($0)
      return nil
    }
    var opened: [Int] = []
    model.onOpenWorktreePalette = { opened.append($0) }
    let window = mount(model)

    type("見積もり", into: window)
    send(Key.enter, "\r", .command, to: window)
    XCTAssertEqual(asks, ["見積もり"])
    XCTAssertEqual(model.store.tasks.count, 3, "足さない")

    send(Key.enter, "\r", .command, to: window)
    XCTAssertEqual(opened, [3], "選んでいる行のタスクの agent を開く")
    XCTAssertEqual(asks.count, 1)
  }

  /// 行の ⌘↵ は、待ちが解けたタスクなら、一覧でも右の欄でも ⌘T の画面を開かずに会話を続きから始める。
  func testCommandEnterOnAResolvedWaitContinuesTheConversationFromTheListAndTheDetail() {
    let condition = WaitCondition(
      WaitConditionRequest(
        description: "レビューが付いたら", command: "gh pr view 214", everyMinutes: 10,
        deadline: DesignSceneFixtures.taskToday.addingTimeInterval(86400),
        conversation: WaitConversation(command: "claude", sessionId: "s-1", workspace: nil)),
      setAt: DesignSceneFixtures.taskToday)
    let model = TaskPaletteSamples.model([
      TaskPaletteSamples.task(1, "a", .inProgress) {
        $0.wait = .resolved(
          WaitResolution(
            waiting: TaskItem.Waiting(
              reason: "レビュー待ち", since: DesignSceneFixtures.taskToday, condition: condition),
            how: .satisfied(output: "レビューが付いた"), at: DesignSceneFixtures.taskToday))
      }
    ])
    var continued: [Int] = []
    var opened: [Int] = []
    model.onContinueWait = {
      continued.append($0)
      return nil
    }
    model.onOpenWorktreePalette = { opened.append($0) }
    let window = mount(model)
    XCTAssertEqual(model.selectedID, .task(1), "前提")

    send(Key.enter, "\r", .command, to: window)
    model.enterDetail()
    flush(window)
    send(Key.enter, "\r", .command, to: window)

    XCTAssertEqual(continued, [1, 1])
    XCTAssertEqual(opened, [])
  }

  /// 押し始めを見ていない ↵ のリピートだけが入力欄に届いても、完了にも追加にもならない。
  func testEnterKeyRepeatAloneInTheFieldDoesNothing() {
    let model = model()
    let window = mount(model)

    send(Key.enter, "\r", repeating: true, to: window)
    type("新しい", into: window)
    send(Key.enter, "\r", repeating: true, to: window)

    XCTAssertEqual(model.store.tasks.map(\.status), [.todo, .todo, .todo], "完了にしない")
    XCTAssertEqual(model.store.tasks.count, 3, "追加しない")
    XCTAssertEqual(model.query, "新しい")
  }

  func testCommandBackspaceDeletesOneTaskEvenWhenHeldDown() {
    let model = model()
    let window = mount(model)

    send(Key.delete, "\u{7F}", .command, to: window)
    send(Key.delete, "\u{7F}", .command, repeating: true, to: window)
    send(Key.delete, "\u{7F}", .command, repeating: true, to: window)

    XCTAssertEqual(model.store.tasks.map(\.id), [1, 2], "消えるのは押した 1 件だけ")
  }

  func testSpaceHeldDownCompletesOneTaskAndTypesNoSpace() {
    let model = model()
    let window = mount(model)

    send(Key.space, " ", to: window)
    send(Key.space, " ", repeating: true, to: window)
    send(Key.space, " ", repeating: true, to: window)

    XCTAssertEqual(model.store.tasks.map(\.status), [.todo, .todo, .done], "完了は押した 1 件だけ")
    XCTAssertEqual(model.query, "", "リピートは入力欄に空白を入れない")
  }

  func testCommandBackspaceWithTextEditsTheFieldInsteadOfDeleting() {
    let model = model()
    let window = mount(model)
    type("a", into: window)
    arrow(Key.down, to: window)
    XCTAssertEqual(model.selectedID, .task(1), "前提: 一致したタスクを選んだ")

    send(Key.delete, "\u{7F}", .command, to: window)

    XCTAssertEqual(model.store.tasks.count, 3, "文字があるときはタスクを消さない")
    XCTAssertEqual(model.query, "", "入力欄の文字を行頭まで消す")
  }

  func testOptionArrowsMoveLikeArrowsAndCommandArrowsJump() {
    let model = model()
    let window = mount(model)

    arrow(Key.down, .command, to: window)
    XCTAssertEqual(model.selectedID, .task(1), "⌘↓ で末尾へ")

    arrow(Key.up, .option, to: window)
    XCTAssertEqual(model.selectedID, .task(2), "⌥↑ は ↑ と同じく前の行へ")
  }

  func testTabAndShiftTabCycleTheTabsWhileTheFieldKeepsTheKeys() {
    let model = model()
    let window = mount(model)

    send(Key.tab, "\t", to: window)
    XCTAssertEqual(model.tab, .github)

    send(Key.tab, "\t", to: window)
    XCTAssertEqual(model.tab, .automation)

    send(Key.tab, "\t", to: window)
    XCTAssertEqual(model.tab, .tasks, "3 つのタブを巡る")

    send(Key.tab, "\u{19}", .shift, to: window)
    XCTAssertEqual(model.tab, .automation, "⇧⇥ は逆に巡る")

    send(Key.tab, "\u{19}", .shift, to: window)
    XCTAssertEqual(model.tab, .github)

    send(Key.tab, "\u{19}", .shift, to: window)
    type("x", into: window)
    XCTAssertEqual(model.tab, .tasks)
    XCTAssertEqual(model.query, "x", "焦点は入力欄に残り、続けて打てる")
  }

  /// 選ぶ状態の ⇥・⇧⇥ は選ぶ状態を保ち、焦点も入力欄に残る（タブを替えないことはモデルのテストが守る）。
  func testTabWhilePickingKeepsPickingAndTheFieldKeepsTheKeys() {
    let model = model()
    model.enterDetail()
    model.area = .detail(.addLink)
    model.beginPickingItem()
    let window = mount(model)

    send(Key.tab, "\t", to: window)
    send(Key.tab, "\u{19}", .shift, to: window)
    type("a", into: window)

    XCTAssertNotNil(model.pick)
    XCTAssertEqual(model.query, "a")
  }

  func testEscapeInTheListClosesTheScreen() {
    let model = model()
    var dismissed = false
    model.onDismiss = { dismissed = true }
    let window = mount(model)

    send(Key.escape, "\u{1B}", to: window)

    XCTAssertTrue(dismissed)
  }

  func testEscapeClosesTheOpenFilterMenuBeforeTheScreen() {
    let model = model()
    var dismissed = false
    model.onDismiss = { dismissed = true }
    model.toggleFilterMenu(.workspace)
    let window = mount(model)

    send(Key.escape, "\u{1B}", to: window)
    XCTAssertNil(model.openFilterMenu)
    XCTAssertFalse(dismissed, "メニューだけを閉じる")

    send(Key.escape, "\u{1B}", to: window)
    XCTAssertTrue(dismissed)
  }

  /// 期限のメニューの値を上から 3 つ続けてクリックすると、3 つともオンになり、メニューは開いたまま。カードは窓が
  /// 広いときの最大の寸法（880 幅・右の欄は 1/3）で、1 つ目をオンにするとドロップダウンの表記が伸びて次の行へ
  /// 折り返す。メニューがドロップダウンを追って動くと、2 つ目のクリックがメニューの外に当たって閉じる。
  func testClickingThreeValuesInARowKeepsTheFilterMenuOpenAndTurnsAllOn() throws {
    let model = model()
    model.toggleFilterMenu(.due)
    let window = mount(model, width: 880, detailWidth: 880 / 3)
    let content = try XCTUnwrap(window.contentView)
    let table = try XCTUnwrap(scrollViews(in: content).first)
    let tableTop = table.convert(table.bounds, to: nil).maxY
    let menu = try XCTUnwrap(scrollViews(in: content).last)
    let frame = menu.convert(menu.bounds, to: nil)

    for (row, bucket) in [TaskDueBucket.overdue, .today, .withinWeek].enumerated() {
      let y =
        frame.maxY - Theme.Space.tick - TaskPaletteRowMetrics.line * (CGFloat(row) + 0.5)
      try click(NSPoint(x: frame.minX + 40, y: y), in: window)
      if row == 0 {
        XCTAssertLessThan(
          table.convert(table.bounds, to: nil).maxY, tableTop, "前提: ドロップダウンが次の行へ折り返す")
      }
      XCTAssertEqual(model.openFilterMenu, .due, "\(row + 1) つ目のクリックの後も開いたまま")
      XCTAssertTrue(model.filter.dues.contains(bucket), "\(row + 1) つ目の値がオン")
    }
  }

  /// view の木を深さ優先でたどった順のスクロール。先頭が表で、絞り込みのメニューはカードの最後に重ねるので末尾。
  private func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
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
    send(Key.space, " ", to: window)

    XCTAssertEqual(status(model, 1), .done, "同じ位置に来た a を完了にする")
  }
}
