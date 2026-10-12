import AppKit
import XCTest

@testable import Orbe

/// 端末へ伝えるフォーカス（その端末が first responder かつ窓が key）を、focus reporting を有効にした端末アプリへ
/// 届くバイト（`ESC[I` / `ESC[O`）で測る。壊れると、キー入力が端末に来ていない間もカーソルが点いたままになり、
/// 端末アプリ（vim の FocusLost・tmux の focus-events）へ得失が届かず、libghostty が押されたままのキーを離さない。
final class SurfaceFocusTests: OrbeTestCase {
  private static let focusIn = TtyDumpTab.hex("\u{1b}[I")
  private static let focusOut = TtyDumpTab.hex("\u{1b}[O")

  /// key にした窓。次のテスト（背面前提）へ持ち越さないため tearDown で下ろす。
  private var shown: [NSWindow] = []
  override func tearDown() {
    shown.forEach { $0.orderOut(nil) }
    shown.removeAll()
    super.tearDown()
  }

  /// first responder の端末は、窓が key になって初めてフォーカスを得て、別の窓（Orbe のダイアログ等）が key に
  /// なると失う。
  func testTerminalHasFocusOnlyWhileItsWindowIsKey() throws {
    let dump = try dump(.focusReport)
    let window = dump.controller.window
    XCTAssertEqual(dump.next(), Self.focusOut, "前提: 有効にした時点のフォーカス（無し）が届く")
    XCTAssertTrue(window.makeFirstResponder(dump.tab.surface))
    PhysicalKey.a.type(into: dump.tab.surface)
    XCTAssertEqual(dump.next(), TtyDumpTab.hex("a"), "窓が key でない間は first responder でもフォーカスを得ない")

    makeKey(window)
    XCTAssertEqual(dump.next(), Self.focusIn)

    let other = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    makeKey(other)
    XCTAssertEqual(dump.next(), Self.focusOut)
  }

  /// workspace の切替で祖先ごと窓から外された端末はフォーカスを失い、戻ると取り戻す。
  func testTerminalDetachedByWorkspaceSwitchLosesFocusAndRegainsItOnReturn() throws {
    let fixture = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: []),
        WorkspaceState(name: "other", rootPath: "/tmp", activeTab: 0, tabs: []),
      ])
    try JSONEncoder().encode(fixture).write(to: workspacesFile())
    let dump = try TtyDumpTab(in: WindowController(), mode: .focusReport)
    let controller = dump.controller
    let other = try XCTUnwrap(controller.regularWorkspaces.last)
    XCTAssertEqual(dump.next(), Self.focusOut, "前提: 有効にした時点のフォーカス（無し）が届く")
    makeKey(controller.window)
    XCTAssertTrue(controller.window.makeFirstResponder(dump.tab.surface))
    XCTAssertEqual(dump.next(), Self.focusIn, "前提: 端末がフォーカスを持つ")

    XCTAssertNotNil(controller.controlActivateWorkspace(workspaceId: other.id))
    XCTAssertEqual(dump.next(), Self.focusOut)

    // 戻りは focus_tab（Attention の「そのタブへ移動」と同じ経路）。workspace を前面に戻し、端末へ焦点を当て直す。
    _ = try controller.controlFocusTab(tabId: dump.tab.id).get()
    XCTAssertEqual(dump.next(), Self.focusIn)
  }

  /// 窓を実際に key にする。key は WindowServer から届くイベントを NSApp が捌いて初めて成立するので、成立するまで配送する。
  private func makeKey(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
    NSApplication.shared.setActivationPolicy(.accessory)
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    shown.append(window)
    let end = Date().addingTimeInterval(2)
    while Date() < end, !window.isKeyWindow {
      guard
        let event = NSApp.nextEvent(
          matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true)
      else { continue }
      NSApp.sendEvent(event)
    }
    XCTAssertTrue(
      window.isKeyWindow, "前提: 窓が key にならない環境ではこの契約を測れない", file: file, line: line)
  }
}
