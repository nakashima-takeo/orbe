import AppKit
import XCTest

@testable import Orbe

/// タブ切替・workspace 切替のフォーカス復元規則
/// （最後にフォーカスしていたペインへ戻る = preferredFocusPane）と、
/// ペイン → WindowController のウィンドウレベル chrome 経路を固定する。
/// WindowControllerWorkspaceTests と同様、実 NSWindow + libghostty ランタイムを使う。
final class WindowControllerFocusRestoreTests: XCTestCase {
  private var tempStore: URL!
  override func setUp() {
    super.setUp()
    tempStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-test-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tempStore
    SettingsPersistence.fileURLOverride = tempStore.appendingPathExtension("settings")
    AppStatePersistence.fileURLOverride = tempStore.appendingPathExtension("appstate")
    // 言語確定済み（returning user）として起動し、初回言語選択 overlay を出さない。
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }
  override func tearDown() {
    WorkspacePersistence.fileURLOverride = nil
    SettingsPersistence.fileURLOverride = nil
    AppStatePersistence.fileURLOverride = nil
    try? FileManager.default.removeItem(at: tempStore)
    super.tearDown()
  }

  /// アクティブタブを分割し、2 枚目のペインへフォーカスを移した状態を作る。
  private func splitAndFocusSecondPane(_ wc: WindowController) -> SurfaceView {
    let first = wc.window.firstResponder as! SurfaceView
    let tc = first.controller!
    tc.split(.horizontal)
    let secondLeaf =
      (tc.rootContainer.subviews.first as! NSSplitView).arrangedSubviews[1] as! SurfaceScrollView
    let second = secondLeaf.surfaceView
    wc.window.makeFirstResponder(second)
    return second
  }

  func testTabSwitchRestoresLastFocusedPane() {
    let wc = WindowController()
    let second = splitAndFocusSecondPane(wc)
    wc.newTab()  // タブ2 へ（フォーカスはタブ2 のペイン）
    XCTAssertFalse(wc.window.firstResponder === second, "新タブではフォーカスが移っている")
    wc.prevTab()  // タブ1 へ戻る
    XCTAssertTrue(
      wc.window.firstResponder === second,
      "タブ切替で最後にフォーカスしていたペインへ戻る")
  }

  func testWorkspaceSwitchRestoresLastFocusedPane() {
    let wc = WindowController()
    let second = splitAndFocusSecondPane(wc)
    wc.createWorkspace(name: "other")  // workspace 2 へ
    XCTAssertFalse(wc.window.firstResponder === second, "別 workspace ではフォーカスが移っている")
    wc.switchWorkspace(to: 0)  // 元 workspace へ戻る
    XCTAssertTrue(
      wc.window.firstResponder === second,
      "workspace 切替で最後にフォーカスしていたペインへ戻る")
  }

  /// ペインからのウィンドウレベル chrome コマンドが WindowController まで届く
  /// （タブ操作は firstResponder の移動で観測する）。
  func testWindowCommandRoutesPaneToWindowController() {
    let wc = WindowController()
    let pane = wc.window.firstResponder as! SurfaceView

    pane.controller?.requestWindowCommand(.newTab)
    XCTAssertFalse(wc.window.firstResponder === pane, "newTab が届けば新タブのペインへフォーカスが移る")

    pane.controller?.requestWindowCommand(.prevTab)
    XCTAssertTrue(wc.window.firstResponder === pane, "prevTab が届けば元タブのペインへ戻る")

    pane.controller?.requestWindowCommand(.nextTab)
    XCTAssertFalse(wc.window.firstResponder === pane, "nextTab が届けば隣タブのペインへ移る")
  }
}
