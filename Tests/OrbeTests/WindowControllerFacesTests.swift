import AppKit
import OrbeSessionLog
import XCTest

@testable import Orbe

/// 面の機構を実窓で固定する——⌘E の往復、⌘W の発火源、背のドラッグ／離す／クリック、タブごとの配置と
/// 焦点の面への復帰、器に包まれた端末の寸法、chrome への投影（現在地・位置ドット）。
///
/// 壊れると何が起きるか。⌘E が焦点の面へ first responder を運ばないとキーが隠れた面へ届く。⌘W の発火源が
/// `.gesture` でなくなると寿命ログが人の操作を「落ちた」と記録し、⇧⌘T のバッジと `orb session closed` の
/// 群れ分けが狂う。背を引いている間にタブの配置を書き換えると毎ポインタで保存と chrome 更新が走る。
/// 離したときの閉じ境がずれると意図しない面が閉じ、焦点が残る面へ移らないと responder が隠れた面に残る。
/// 隠れている端末が resize されると scrollback が折り返し直され、復元した配置に戻らないとタブを切り替える
/// たびに分割が消える。chrome が焦点の面を映さないと現在地とドットが実態と別の面を指す。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerFacesTests: OrbeTestCase {
  override func setUp() {
    super.setUp()
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  private func restore(_ tabs: [TabState], rootPath: String = "/tmp") throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [WorkspaceState(name: "main", rootPath: rootPath, activeTab: 0, tabs: tabs)])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  private func pump(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
  }

  private func layout(_ wc: WindowController) {
    wc.window.contentView?.layoutSubtreeIfNeeded()
  }

  /// 器の内容幅（窓の content 幅から背を除いた値）。
  private func contentWidth(_ wc: WindowController) -> CGFloat {
    wc.model.content.bounds.width - FaceGeometry.spine
  }

  // MARK: - ⌘E

  /// 分割していなければ端末 ⇄ エディター全面を往復し、first responder も焦点の面へ移る。
  func testToggleEditorFaceSwapsTheFullFaceAndMovesFocus() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 1, focus: .editor))
    XCTAssertTrue(wc.window.firstResponder === tab.view.editor, "エディター pane が first responder")

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertEqual(tab.faces, .terminalOnly)
    XCTAssertTrue(wc.window.firstResponder === tab.surface, "端末 surface へ戻る")
  }

  /// 分割中は幅を変えず焦点だけが往復する。
  func testToggleEditorFaceWhileSplitOnlyMovesFocus() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 0.5, focus: .editor))
    XCTAssertTrue(wc.window.firstResponder === tab.view.editor)

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 0.5, focus: .terminal))
    XCTAssertTrue(wc.window.firstResponder === tab.surface)
  }

  /// 0 タブでは何も起きない。
  func testToggleEditorFaceWithoutTabsDoesNothing() throws {
    let wc = WindowController()
    wc.closeTab(try XCTUnwrap(wc.activeTab), origin: .gesture)
    XCTAssertNil(wc.activeTab, "前提: 0 タブ")

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertNil(wc.activeTab)
    XCTAssertTrue(wc.current.tabs.isEmpty)
  }

  // MARK: - ⌘W

  /// ⌘W はアクティブタブを人のジェスチャとして閉じる（寿命ログの closed に `.gesture` が載る）。
  func testCloseTabCommandClosesTheActiveTabAsAGesture() throws {
    let wc = try restore([TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
    let tab = try XCTUnwrap(wc.activeTab)
    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))

    wc.handleWindowCommand(.closeTab)
    pump(0.2)

    XCTAssertTrue(wc.current.tabs.isEmpty, "アクティブタブが閉じる")
    let events = try SessionLogReader.read(XCTUnwrap(AgentSessionLog.fileURL)).events
    XCTAssertEqual(events.last?.closeOrigin, .gesture, "⌘W は人のジェスチャとして記録される")
  }

  // MARK: - 背

  /// 背を引くと面はポインタに追従するが、タブの配置は離すまで書き換えず、離したときに 1 回だけ確定する。
  func testSpineDragFollowsThePointerAndCommitsOnRelease() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    var changes = 0
    tab.onFacesChange = { changes += 1 }
    let spine = tab.view.spine
    let y = spine.centerInWindow.y

    spine.mouseDown(with: .mouse(.leftMouseDown, at: spine.centerInWindow, in: wc.window))
    spine.mouseDragged(with: .mouse(.leftMouseDragged, at: NSPoint(x: 300, y: y), in: wc.window))
    spine.mouseDragged(with: .mouse(.leftMouseDragged, at: NSPoint(x: 400, y: y), in: wc.window))

    XCTAssertEqual(spine.frame.minX, 400, "背はポインタの位置に立つ")
    XCTAssertEqual(tab.view.resolved.editorWidth, 400, "エディター面はポインタまで広がる")
    XCTAssertFalse(tab.view.editor.isHiddenOrHasHiddenAncestor, "引き出したエディター面は見えている")
    XCTAssertEqual(tab.faces, .terminalOnly, "離すまでタブの配置は変わらない")
    XCTAssertEqual(changes, 0)

    spine.mouseUp(with: .mouse(.leftMouseUp, at: NSPoint(x: 400, y: y), in: wc.window))
    XCTAssertEqual(tab.faces.editorRatio * contentWidth(wc), 400, accuracy: 0.5, "離した幅で確定")
    XCTAssertEqual(tab.faces.focus, .terminal, "焦点は掴んだときのまま")
    XCTAssertEqual(changes, 1, "確定は 1 回")
  }

  /// 閉じる境より狭い面を残したまま離すと、その面が閉じて隣が全面になる。閉じたのが焦点の面なら
  /// 焦点と first responder は残る面へ移る。
  func testSpineReleaseNearTheEdgeClosesTheFace() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    let spine = tab.view.spine
    let y = spine.centerInWindow.y

    spine.mouseDown(with: .mouse(.leftMouseDown, at: spine.centerInWindow, in: wc.window))
    spine.mouseDragged(with: .mouse(.leftMouseDragged, at: NSPoint(x: 150, y: y), in: wc.window))
    spine.mouseUp(with: .mouse(.leftMouseUp, at: NSPoint(x: 150, y: y), in: wc.window))
    XCTAssertEqual(tab.faces, .terminalOnly, "エディター 150 は閉じる")
    XCTAssertTrue(wc.window.firstResponder === tab.surface)

    let nearRight = contentWidth(wc) - 100
    spine.mouseDown(with: .mouse(.leftMouseDown, at: spine.centerInWindow, in: wc.window))
    spine.mouseDragged(
      with: .mouse(.leftMouseDragged, at: NSPoint(x: nearRight, y: y), in: wc.window))
    spine.mouseUp(with: .mouse(.leftMouseUp, at: NSPoint(x: nearRight, y: y), in: wc.window))
    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 1, focus: .editor), "端末 100 は閉じる")
    XCTAssertTrue(wc.window.firstResponder === tab.view.editor, "焦点は残ったエディターへ")
  }

  /// 掴んだ瞬間に焦点の面へ first responder が戻り、引いて離しても焦点の面は変わらない。
  func testSpineGrabReturnsFocusToTheFocusedFaceAndDragKeepsIt() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .editor), animated: false)
    layout(wc)
    wc.window.makeFirstResponder(nil)
    XCTAssertFalse(wc.window.firstResponder === tab.view.editor, "前提: 焦点の面から外れている")
    let spine = tab.view.spine
    let y = spine.centerInWindow.y

    spine.mouseDown(with: .mouse(.leftMouseDown, at: spine.centerInWindow, in: wc.window))
    XCTAssertTrue(wc.window.firstResponder === tab.view.editor, "掴んだ瞬間に焦点の面へ戻る")

    spine.mouseDragged(with: .mouse(.leftMouseDragged, at: NSPoint(x: 300, y: y), in: wc.window))
    spine.mouseUp(with: .mouse(.leftMouseUp, at: NSPoint(x: 300, y: y), in: wc.window))
    XCTAssertEqual(tab.faces.focus, .editor, "焦点はエディターのまま")
    XCTAssertEqual(tab.faces.editorRatio * contentWidth(wc), 300, accuracy: 0.5)
    XCTAssertTrue(wc.window.firstResponder === tab.view.editor)
  }

  /// 閾値（4px）未満しか動かさずに離せばクリック（隣の面を全開）。
  func testSpineMoveUnderTheThresholdIsAClick() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    let spine = tab.view.spine
    let grab = spine.centerInWindow

    spine.mouseDown(with: .mouse(.leftMouseDown, at: grab, in: wc.window))
    spine.mouseDragged(
      with: .mouse(.leftMouseDragged, at: NSPoint(x: grab.x + 3, y: grab.y), in: wc.window))
    spine.mouseUp(with: .mouse(.leftMouseUp, at: NSPoint(x: grab.x + 3, y: grab.y), in: wc.window))

    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 1, focus: .editor), "隠れていたエディターが全開")
    XCTAssertTrue(wc.window.firstResponder === tab.view.editor)
  }

  /// 背の中のどこを掴んでも、引いた距離だけ面が動く（掴んだ瞬間に跳ばない）。
  func testSpineDragMovesTheFaceByTheDraggedDistance() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    layout(wc)
    let spine = tab.view.spine
    let editorWidth = tab.view.resolved.editorWidth
    let grab = spine.centerInWindow

    spine.mouseDown(with: .mouse(.leftMouseDown, at: grab, in: wc.window))
    spine.mouseDragged(
      with: .mouse(.leftMouseDragged, at: NSPoint(x: grab.x + 10, y: grab.y), in: wc.window))

    XCTExpectFailure(
      "背はポインタの x をそのままエディター幅にするため、背の中で掴んだ位置（中央なら 7px）ぶん跳ぶ"
    ) {
      XCTAssertEqual(tab.view.resolved.editorWidth, editorWidth + 10, "引いた 10px だけ広がる")
    }
  }

  // MARK: - タブごとの配置と焦点の面

  /// 配置はタブごとに持ち、タブを切り替えても自分の配置と焦点の面へ戻る。
  func testTabSwitchRestoresEachTabsOwnLayoutAndFocusedFace() throws {
    let wc = WindowController()
    let first = try XCTUnwrap(wc.activeTab)
    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertTrue(wc.window.firstResponder === first.view.editor, "前提: タブ 1 はエディター焦点")

    wc.newTab()
    let second = try XCTUnwrap(wc.activeTab)
    XCTAssertEqual(second.faces, .terminalOnly, "新タブは端末だけ")
    XCTAssertTrue(wc.window.firstResponder === second.surface)

    wc.prevTab()
    XCTAssertEqual(first.faces, FaceLayout(editorRatio: 1, focus: .editor), "タブ 1 の配置は残る")
    XCTAssertTrue(wc.window.firstResponder === first.view.editor, "タブ 1 の焦点の面へ戻る")
  }

  /// ヘルプを閉じると焦点の面（エディター pane）へ戻る。ヘルプの入力欄が first responder を取るのは
  /// SwiftUI の focus 経由で同期には決まらないので、奪われた状態は明示的に作る。
  func testHelpDismissReturnsFocusToTheEditorPane() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    wc.handleWindowCommand(.toggleEditorFace)

    wc.showHelp()
    wc.window.makeFirstResponder(nil)
    XCTAssertFalse(wc.window.firstResponder === tab.view.editor, "前提: 焦点はヘルプ側にある")
    wc.dismissHelp()
    pump(0.05)

    XCTAssertTrue(wc.window.firstResponder === tab.view.editor)
  }

  /// 制御 API の `focus_tab` もそのタブの焦点の面へ着地する。
  func testControlFocusTabLandsOnTheFocusedFace() throws {
    let wc = WindowController()
    let first = try XCTUnwrap(wc.activeTab)
    wc.handleWindowCommand(.toggleEditorFace)
    wc.newTab()

    _ = wc.controlFocusTab(tabId: first.id)

    XCTAssertTrue(first === wc.activeTab)
    XCTAssertTrue(wc.window.firstResponder === first.view.editor)
  }

  /// 復元したタブは保存した配置と焦点の面で起き、端末は見えている面の寸法を持つ。
  func testRestoredTabWakesWithItsSavedLayoutAndFocusedFace() throws {
    let wc = try restore([
      TabState(
        cwd: "/tmp", agent: nil, explicitTitle: nil,
        faces: FaceLayout(editorRatio: 0.5, focus: .editor))
    ])
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)

    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 0.5, focus: .editor))
    XCTAssertTrue(wc.window.firstResponder === tab.view.editor)
    let content = wc.model.content.bounds.size
    XCTAssertGreaterThan(content.width, 0, "前提: content が実サイズを持つ")
    XCTAssertEqual(
      tab.surface.bounds.size,
      CGSize(
        width: ((content.width - FaceGeometry.spine) / 2).rounded(),
        height: content.height - FaceGeometry.focusBand), "端末は分割後の面の寸法")
  }

  // MARK: - 器に包まれた端末

  /// エディターに覆われている間は窓を resize しても端末の寸法が変わらず、戻したときに今の窓幅で置き直す。
  func testSurfaceKeepsItsSizeWhileCoveredByTheEditor() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    let visible = tab.surface.bounds.size
    XCTAssertGreaterThan(visible.width, 0, "前提: 端末が実サイズを持つ")

    wc.handleWindowCommand(.toggleEditorFace)
    layout(wc)
    XCTAssertEqual(tab.surface.bounds.size, visible, "覆われた瞬間に縮めない")

    wc.window.setContentSize(NSSize(width: 1000, height: 600))
    layout(wc)
    XCTAssertEqual(tab.surface.bounds.size, visible, "覆われている間の窓の resize に追従しない")

    wc.handleWindowCommand(.toggleEditorFace)
    layout(wc)
    let content = wc.model.content.bounds.size
    XCTAssertEqual(
      tab.surface.bounds.size,
      CGSize(
        width: content.width - FaceGeometry.spine, height: content.height - FaceGeometry.focusBand),
      "戻したら今の窓幅で置き直す")
  }

  // MARK: - chrome

  /// 上段の現在地は焦点の面に追従する——端末焦点は cwd、エディター焦点は worktree ルート。
  func testLocationFollowsTheFocusedFace() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-faces-\(UUID().uuidString)")
    let src = root.appendingPathComponent("src")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let wc = try restore(
      [TabState(cwd: src.path, agent: nil, explicitTitle: nil)], rootPath: root.path)

    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.location, src.path, "端末焦点は cwd")

    wc.handleWindowCommand(.toggleEditorFace)
    wc.flushChrome()
    XCTAssertEqual(
      wc.statusModel.location, GitWorktreeRoot.normalizedPath(root.path), "エディター焦点は worktree ルート")
  }

  /// 位置ドットはアクティブタブの面の可視と焦点を映し、0 タブでは無い。
  func testFaceDotsMirrorTheActiveTabsFaces() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)

    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.faceDots, .init(editor: .off, terminal: .focus), "端末だけ")

    wc.handleWindowCommand(.toggleEditorFace)
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.faceDots, .init(editor: .focus, terminal: .off), "エディター全面")

    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.faceDots, .init(editor: .on, terminal: .focus), "分割で端末焦点")

    wc.closeTab(tab, origin: .gesture)
    wc.flushChrome()
    XCTAssertNil(wc.statusModel.faceDots, "0 タブでは無い")
  }
}
