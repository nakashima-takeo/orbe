import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 本物の `WorktreePaletteCard` を実 `NSWindow` に載せ、実 `NSEvent` の ⇥ / ⇧⇥ を入力欄へ届ける。
/// ⇧⇥ は AppKit では backtab の文字で届き、SwiftUI の `.tab` 判定だけでは拾えない形がある——拾えないと
/// ⇧⇥ が起動先を回したり、焦点が入力欄から外へ逃げて ↑↓ と打鍵が効かなくなる。
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
}
