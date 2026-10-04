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
    wc.createWorkspace(name: "other", rootPath: "/tmp/ws-other")  // workspace 2 へ
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

/// 面（エディター pane・端末 surface）のクリックと背の操作が、焦点の面をどう動かすかを実窓で固定する。
extension WindowControllerFocusRestoreTests {
  /// 分割中にエディター面をクリックして焦点にし、背をクリックすると、残るのは焦点の面（エディター）。
  func testSpineClickKeepsTheFocusedEditorFace() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    wc.window.contentView?.layoutSubtreeIfNeeded()
    let pane = tab.view.editor
    XCTAssertGreaterThan(pane.bounds.width, 0, "前提: 分割でエディター面が見えている")

    pane.mouseDown(with: .mouse(.leftMouseDown, at: pane.centerInWindow, in: wc.window))
    XCTAssertTrue(wc.window.firstResponder === pane, "クリックでエディター pane が first responder")
    XCTAssertEqual(tab.faces.focus, .editor, "タブの焦点の面がエディターへ追従する")

    let spine = tab.view.spine
    spine.mouseDown(with: .mouse(.leftMouseDown, at: spine.centerInWindow, in: wc.window))
    spine.mouseUp(with: .mouse(.leftMouseUp, at: spine.centerInWindow, in: wc.window))
    XCTAssertEqual(
      tab.faces, FaceLayout(editorRatio: 1, focus: .editor), "背クリックで焦点の面（エディター）が全面に残る")
    XCTAssertTrue(wc.window.firstResponder === pane, "焦点はエディター pane のまま")
  }
}
