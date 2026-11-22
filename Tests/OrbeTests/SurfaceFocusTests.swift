import AppKit
import XCTest

@testable import Orbe

/// 端末へ伝えるフォーカス（その端末が first responder かつウィンドウが key）を、focus reporting を有効にした端末アプリへ
/// 届くバイト（`ESC[I` / `ESC[O`）で測る。壊れると、キー入力が端末に来ていない間もカーソルが点いたままになり、
/// 端末アプリ（vim の FocusLost・tmux の focus-events）へ得失が届かず、libghostty が押されたままのキーを離さない。
final class SurfaceFocusTests: OrbeTestCase {
  private static let focusIn = TtyDumpTab.hex("\u{1b}[I")
  private static let focusOut = TtyDumpTab.hex("\u{1b}[O")

  /// 端末は first responder でもウィンドウが key になって初めてフォーカスを得る。key のウィンドウの中でフォーカスが端末から外れるか、
  /// ウィンドウが key でなくなる（別のウィンドウや別のアプリが key になる）と失う。
  func testTerminalHasFocusOnlyWhileFirstResponderOfTheKeyWindow() throws {
    let window = OrbeWindowFake()
    let dump = try dump(.focusReport, window: window)
    XCTAssertEqual(dump.next(), Self.focusOut, "前提: 有効にした時点のフォーカス（無し）が届く")
    XCTAssertTrue(window.makeFirstResponder(dump.tab.surface))
    PhysicalKey.a.type(into: dump.tab.surface)
    XCTAssertEqual(dump.next(), TtyDumpTab.hex("a"), "ウィンドウが key でない間は first responder でもフォーカスを得ない")

    window.isKey = true
    XCTAssertEqual(dump.next(), Self.focusIn)

    XCTAssertTrue(window.makeFirstResponder(nil))
    XCTAssertEqual(dump.next(), Self.focusOut, "key のウィンドウの中でフォーカスが端末から外れると失う")
    XCTAssertTrue(window.makeFirstResponder(dump.tab.surface))
    XCTAssertEqual(dump.next(), Self.focusIn)

    window.isKey = false
    XCTAssertEqual(dump.next(), Self.focusOut)
  }

  /// workspace の切替で祖先ごとウィンドウから外された端末はフォーカスを失い、戻ると取り戻す。
  func testTerminalDetachedByWorkspaceSwitchLosesFocusAndRegainsItOnReturn() throws {
    let fixture = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: "/tmp", activeTab: 0, tabs: []),
        WorkspaceState(name: "other", rootPath: "/tmp", activeTab: 0, tabs: []),
      ])
    try JSONEncoder().encode(fixture).write(to: workspacesFile())
    let window = OrbeWindowFake()
    let dump = try TtyDumpTab(in: WindowController(window: window), mode: .focusReport)
    let controller = dump.controller
    let other = try XCTUnwrap(controller.regularWorkspaces.last)
    XCTAssertEqual(dump.next(), Self.focusOut, "前提: 有効にした時点のフォーカス（無し）が届く")
    window.isKey = true
    XCTAssertTrue(window.makeFirstResponder(dump.tab.surface))
    XCTAssertEqual(dump.next(), Self.focusIn, "前提: 端末がフォーカスを持つ")

    XCTAssertNotNil(controller.controlActivateWorkspace(workspaceId: other.id))
    XCTAssertEqual(dump.next(), Self.focusOut)

    // 戻りは focus_tab（Attention の「そのタブへ移動」と同じ経路）。workspace を前面に戻し、端末へフォーカスを当て直す。
    _ = try controller.controlFocusTab(tabId: dump.tab.id).get()
    XCTAssertEqual(dump.next(), Self.focusIn)
  }
}
