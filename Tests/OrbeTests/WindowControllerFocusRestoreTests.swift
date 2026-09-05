import AppKit
import XCTest

@testable import Orbe

/// タブ切替・workspace 切替のフォーカス復元規則（アクティブタブの surface へ戻る）と、
/// surface → WindowController のウィンドウレベル chrome 経路を固定する。
/// WindowControllerWorkspaceTests と同様、実 NSWindow + libghostty ランタイムを使う。
final class WindowControllerFocusRestoreTests: OrbeTestCase {
  override func setUp() {
    super.setUp()
    // 言語確定済み（returning user）として起動し、初回言語選択 overlay を出さない。
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  func testTabSwitchRestoresActiveTabSurface() {
    let wc = WindowController()
    let first = wc.window.firstResponder as! SurfaceView
    wc.newTab()  // タブ2 へ（フォーカスはタブ2 の surface）
    XCTAssertFalse(wc.window.firstResponder === first, "新タブではフォーカスが移っている")
    wc.prevTab()  // タブ1 へ戻る
    XCTAssertTrue(wc.window.firstResponder === first, "タブ切替でそのタブの surface へ戻る")
  }

  func testWorkspaceSwitchRestoresActiveTabSurface() {
    let wc = WindowController()
    let first = wc.window.firstResponder as! SurfaceView
    wc.createWorkspace(name: "other")  // workspace 2 へ
    XCTAssertFalse(wc.window.firstResponder === first, "別 workspace ではフォーカスが移っている")
    wc.switchWorkspace(to: 0)  // 元 workspace へ戻る
    XCTAssertTrue(wc.window.firstResponder === first, "workspace 切替でアクティブタブの surface へ戻る")
  }

  /// surface からのウィンドウレベル chrome コマンドが WindowController まで届く
  /// （タブ操作は firstResponder の移動で観測する）。
  func testWindowCommandRoutesSurfaceToWindowController() {
    let wc = WindowController()
    let surface = wc.window.firstResponder as! SurfaceView

    surface.perform(.newTab)
    XCTAssertFalse(wc.window.firstResponder === surface, "newTab が届けば新タブの surface へフォーカスが移る")

    surface.perform(.prevTab)
    XCTAssertTrue(wc.window.firstResponder === surface, "prevTab が届けば元タブの surface へ戻る")

    surface.perform(.nextTab)
    XCTAssertFalse(wc.window.firstResponder === surface, "nextTab が届けば隣タブの surface へ移る")
  }
}
