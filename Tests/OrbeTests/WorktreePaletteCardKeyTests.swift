import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 本物の `WorktreePaletteCard` を実 `NSWindow` に載せ、実 `NSEvent` のキーを入力欄へ届ける。
/// ⇧⇥ は AppKit では backtab の文字で届き、SwiftUI の `.tab` 判定だけでは拾えない形がある——拾えないと
/// ⇧⇥ が起動先を回したり、焦点が入力欄から外へ逃げて ↑↓ と打鍵が効かなくなる。ベースを選ぶ画面は
/// 入力欄を一覧と使い回すので、行き先の切り替えを誤ると、絞り込みが一覧の入力を書き換える・戻った後に
/// キーが効かない・↵ が別の候補に決まる、のどれかになる。
@MainActor
final class WorktreePaletteCardKeyTests: PaletteCardWindowTestCase {

  private func mount(_ model: WorktreePaletteModel) -> NSWindow {
    NSApplication.shared.setActivationPolicy(.accessory)
    let window = KeyWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 760, height: 520),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = NSHostingView(
      rootView: WorktreePaletteCard(model: model, maxHeight: 520).frame(width: 720))
    window.makeKeyAndOrderFront(nil)
    hold(window)
    pump(0.4)
    return window
  }

  private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
  }

  private var held: [NSWindow] = []
  private func hold(_ window: NSWindow) { held.append(window) }

  override func tearDown() {
    held.forEach { $0.orderOut(nil) }
    held.removeAll()
    super.tearDown()
  }

  private func sendTab(shift: Bool, to window: NSWindow) {
    let characters = shift ? "\u{19}" : "\t"
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: 48)
    else { return XCTFail("キーイベントを作れない") }
    NSApp.sendEvent(event)
    pump(0.15)
  }

  /// 作成行の選択中、⇧⇥ はベースだけを回し、⇥ は起動先だけを回す。
  func testShiftTabCyclesTheBaseAndTabCyclesTheTarget() {
    let model = DesignSceneFixtures.worktreePaletteNewBranchModel()
    let window = mount(model)
    XCTAssertEqual(model.selectedBaseChoice?.role, .previous, "前提: 作成行・初めは前回")

    sendTab(shift: true, to: window)
    XCTAssertEqual(model.selectedBaseChoice?.role, .defaultBranch, "⇧⇥ でベースが進む")
    XCTAssertEqual(model.selectedTargetName, "claude", "⇧⇥ は起動先を動かさない")

    sendTab(shift: false, to: window)
    XCTAssertEqual(model.selectedTargetName, "shell", "⇥ で起動先が進む")
    XCTAssertEqual(model.selectedBaseChoice?.role, .defaultBranch, "⇥ はベースを動かさない")

    sendTab(shift: true, to: window)
    XCTAssertEqual(model.selectedBaseChoice?.role, .current, "焦点は入力欄に残り、続けて効く")
  }

  /// 「ほか…」で ↵ するとベースを選ぶ画面になり、同じ入力欄が絞り込みを受ける（一覧の入力は残る）。
  /// ↵ で決めると一覧へ戻り、選んだ名前がベースになって、入力欄はそのまま ⇧⇥ を受ける。
  func testBasePickerFiltersInTheSameFieldAndReturnsWithThePickedBase() {
    let model = DesignSceneFixtures.worktreePaletteNewBranchModel()
    let window = mount(model)
    for _ in 0..<3 { sendTab(shift: true, to: window) }
    XCTAssertEqual(model.selectedBaseChoice?.role, .other, "前提: ⇧⇥ で「ほか…」に止まった")

    send(36, "\r", to: window)
    XCTAssertEqual(model.mode, .basePicker, "「ほか…」の ↵ でベースを選ぶ画面を開く")
    type("fetch", into: window)
    XCTAssertEqual(model.basePicker?.query, "fetch", "打鍵はベースの絞り込みに入る")
    XCTAssertEqual(model.query, "feat/base-picker", "一覧の入力は書き換わらない")
    XCTAssertEqual(model.basePicker?.items.map(\.name), ["origin/feat/fetch-progress"])

    send(36, "\r", to: window)

    XCTAssertEqual(model.mode, .list, "決めると一覧へ戻る")
    XCTAssertEqual(model.selectedBaseChoice?.role, .picked)
    XCTAssertEqual(model.selectedBaseChoice?.name, "origin/feat/fetch-progress")
    XCTAssertEqual(model.query, "feat/base-picker")
    sendTab(shift: true, to: window)
    XCTAssertEqual(model.selectedBaseChoice?.role, .other, "戻った後も入力欄が ⇧⇥ を受ける")
  }

  /// ベースを選ぶ画面の ↵ は、↑↓ で動かしたカーソルの候補に決める。
  func testEnterInTheBasePickerDecidesTheCandidateUnderTheCursor() {
    let model = DesignSceneFixtures.worktreePaletteBasePickerModel()
    let window = mount(model)
    type("origin", into: window)
    send(125, "\u{F701}", to: window)
    send(125, "\u{F701}", to: window)
    XCTAssertEqual(
      model.basePicker?.selectedItem?.name, "origin/feat/fetch-progress", "前提: ↓↓ でカーソルが動いた")

    send(36, "\r", to: window)

    XCTAssertEqual(model.selectedBaseChoice?.name, "origin/feat/fetch-progress")
  }

  /// ベースを選ぶ画面の esc は選ばずに一覧へ戻り、ベースは「ほか…」のまま。入力欄は一覧のキーを受け直す。
  func testEscapeFromTheBasePickerKeepsOtherAndTheFieldStillWorks() {
    let model = DesignSceneFixtures.worktreePaletteBasePickerModel()
    let window = mount(model)
    XCTAssertEqual(model.mode, .basePicker, "前提: ベースを選ぶ画面")

    send(53, "\u{1B}", to: window)

    XCTAssertEqual(model.mode, .list)
    XCTAssertEqual(model.selectedBaseChoice?.role, .other)
    XCTAssertNil(model.pickedBase)
    sendTab(shift: true, to: window)
    XCTAssertEqual(model.selectedBaseChoice?.role, .previous, "⇧⇥ が末尾から先頭へ回る")
  }

  private func type(_ text: String, into window: NSWindow) {
    for character in text { send(0, String(character), to: window) }
  }

  private func backspace(repeating: Bool = false, to window: NSWindow) {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
        isARepeat: repeating, keyCode: 51)
    else { return XCTFail("キーイベントを作れない") }
    NSApp.sendEvent(event)
    pump(0.15)
  }

  /// タスクから開いた ⌘T の ⌫ は、打った文字を先に消し、入力欄が空になってから押した ⌫ でタスクの札を外す。
  /// 文字を消そうと押し続けたキーリピートでは外さない。
  func testBackspaceRemovesTheTaskOnlyFromAnEmptyFieldAndNotByKeyRepeat() {
    let model = DesignSceneFixtures.worktreePaletteIssueModel()
    let window = mount(model)
    type("i", into: window)

    backspace(to: window)
    XCTAssertEqual(model.query, "", "まず文字を消す")
    XCTAssertEqual(model.taskContextID, 3, "文字を消した ⌫ では外さない")

    backspace(repeating: true, to: window)
    XCTAssertEqual(model.taskContextID, 3, "押し続けたリピートでは外さない")

    backspace(to: window)
    XCTAssertNil(model.taskContextID, "空の入力欄の ⌫ で外す")
  }

  /// 開いている間にタスクや GitHub の値が変わると（PR のブランチ名が届く等）、カードが provider に組み直させる。
  func testTheCardAsksForARebuildWhenTheTasksInputsChange() throws {
    let model = DesignSceneFixtures.worktreePalettePullRequestModel()
    var rebuilds = 0
    model.onTaskInputsChanged = { rebuilds += 1 }
    _ = mount(model)
    let before = rebuilds

    var update = TaskUpdate()
    update.links = []
    _ = try model.tasks.update(4, update)
    pump(0.3)

    XCTAssertGreaterThan(rebuilds, before)
  }
}
