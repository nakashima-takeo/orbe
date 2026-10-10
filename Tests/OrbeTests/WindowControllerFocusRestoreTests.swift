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
    wc.newTab()
    let second = wc.window.firstResponder as! SurfaceView
    XCTAssertFalse(second === surface, "前提: 新タブの surface へフォーカスが移っている")

    second.perform(.prevTab)
    XCTAssertTrue(wc.window.firstResponder === surface, "prevTab が届けば元タブの surface へ戻る")

    surface.perform(.nextTab)
    XCTAssertFalse(wc.window.firstResponder === surface, "nextTab が届けば隣タブの surface へ移る")
  }
}

/// 面（エディター pane・端末 surface）のクリックと取っ手の操作が、焦点の面をどう動かすかを実窓で固定する。
extension WindowControllerFocusRestoreTests {
  /// 分割中にエディター面をクリックして焦点にし、継ぎ目を押すと、残るのは焦点の面（エディター）。
  func testSeamClickKeepsTheFocusedEditorFace() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    tab.group.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    wc.window.contentView?.layoutSubtreeIfNeeded()
    let pane = tab.group.view.editor
    XCTAssertGreaterThan(pane.bounds.width, 0, "前提: 分割でエディター面が見えている")

    pane.mouseDown(with: .mouse(.leftMouseDown, at: pane.centerInWindow, in: wc.window))
    XCTAssertTrue(wc.window.firstResponder === pane, "クリックでエディター pane が first responder")
    XCTAssertEqual(tab.group.faces.focus, .editor, "タブの焦点の面がエディターへ追従する")

    let handle = tab.group.view.handle
    handle.mouseDown(with: .mouse(.leftMouseDown, at: handle.centerInWindow, in: wc.window))
    handle.mouseUp(with: .mouse(.leftMouseUp, at: handle.centerInWindow, in: wc.window))
    XCTAssertEqual(
      tab.group.faces, FaceLayout(editorRatio: 1, focus: .editor), "継ぎ目を押すと焦点の面（エディター）が全面に残る")
    XCTAssertTrue(wc.window.firstResponder === pane, "焦点はエディター pane のまま")
  }
}
