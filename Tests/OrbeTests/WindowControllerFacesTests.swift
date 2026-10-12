import AppKit
import OrbeSessionLog
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 面の機構を実窓で固定する——⌘E の往復、⌘W の発火源、引き手・継ぎ目を引く／離す／押す、連ごとの配置と
/// 焦点の面への復帰、器に包まれた端末の寸法、chrome への投影（現在地・位置ドット）。
///
/// 壊れると何が起きるか。⌘E が焦点の面へ first responder を運ばないとキーが隠れた面へ届く。⌘W の発火源が
/// `.gesture` でなくなると寿命ログが人の操作を「落ちた」と記録し、⇧⌘T のバッジと `orb session closed` の
/// 群れ分けが狂う。取っ手を引いている間にタブの配置を書き換えると毎ポインタで保存と chrome 更新が走る。
/// 離したときの閉じ境がずれると意図しない面が閉じ、焦点が残る面へ移らないと responder が隠れた面に残る。
/// 隠れている端末が resize されると scrollback が折り返し直され、復元した配置に戻らないと連を切り替える
/// たびに分割が消える。chrome が焦点の面を映さないと現在地とドットが実態と別の面を指す。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerFacesTests: OrbeTestCase {
  override func setUp() {
    super.setUp()
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  private func restore(
    _ tabs: [TabState], groups: [GroupState] = [], rootPath: String = "/tmp"
  ) throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(name: "main", rootPath: rootPath, activeTab: 0, tabs: tabs, groups: groups)
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  func pump(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
  }

  func layout(_ wc: WindowController) {
    wc.window.contentView?.layoutSubtreeIfNeeded()
  }

  /// 器の幅（窓の content 幅）。
  func facesWidth(_ wc: WindowController) -> CGFloat {
    wc.model.content.bounds.width
  }

  // MARK: - ⌘E

  /// 分割していなければ端末 ⇄ エディター全面を往復し、first responder も焦点の面へ移る。
  func testToggleEditorFaceSwapsTheFullFaceAndMovesFocus() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertEqual(tab.group.faces, FaceLayout(editorRatio: 1, focus: .editor))
    XCTAssertTrue(
      wc.window.firstResponder === tab.group.view.editor, "エディター pane が first responder")

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertEqual(tab.group.faces, .terminalOnly)
    XCTAssertTrue(wc.window.firstResponder === tab.surface, "端末 surface へ戻る")
  }

  /// 分割中は幅を変えず焦点だけが往復する。
  func testToggleEditorFaceWhileSplitOnlyMovesFocus() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    tab.group.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertEqual(tab.group.faces, FaceLayout(editorRatio: 0.5, focus: .editor))
    XCTAssertTrue(wc.window.firstResponder === tab.group.view.editor)

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertEqual(tab.group.faces, FaceLayout(editorRatio: 0.5, focus: .terminal))
    XCTAssertTrue(wc.window.firstResponder === tab.surface)
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

  // MARK: - 引き手・継ぎ目

  /// 端末だけのときに左縁の引き手を掴んで引くと、取っ手はポインタに 1:1 で付き、面が追従する。タブの配置は離すまで
  /// 書き換えず、離したときに 1 回だけ確定する（ゆっくり離せばその位置で分割として残る）。
  func testNotchDragFollowsThePointerAndCommitsOnRelease() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    var changes = 0
    tab.group.onFacesChange = { changes += 1 }
    let handle = tab.group.view.handle
    let grab = handle.centerInWindow
    let offset = grab.x - handle.frame.minX
    let y = grab.y

    handle.mouseDown(with: .mouse(.leftMouseDown, at: grab, in: wc.window))
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: NSPoint(x: 300, y: y), in: wc.window))
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: NSPoint(x: 400, y: y), in: wc.window))

    XCTAssertEqual(handle.frame.minX, 400 - offset, "取っ手は掴んだ点のずれを保ってポインタに追従する")
    XCTAssertTrue(handle.frame.minX <= 400 && 400 <= handle.frame.maxX, "取っ手はポインタの下")
    let ratio = try XCTUnwrap(FaceGeometry.ratio(hx: 400 - offset, width: facesWidth(wc)))
    XCTAssertFalse(tab.group.view.editor.isHiddenOrHasHiddenAncestor, "引き出したエディター面は見えている")
    XCTAssertEqual(tab.group.faces, .terminalOnly, "離すまでタブの配置は変わらない")
    XCTAssertEqual(changes, 0)

    handle.mouseUp(with: .mouse(.leftMouseUp, at: NSPoint(x: 400, y: y), in: wc.window))
    XCTAssertEqual(tab.group.faces.editorRatio, ratio, accuracy: 0.0001, "離した位置で確定")
    XCTAssertEqual(tab.group.faces.focus, .terminal, "焦点は掴んだときのまま")
    XCTAssertEqual(changes, 1, "確定は 1 回")
  }

  /// 端の近く（勢いで滑った先が端から 24 以内）で離すと、その面が閉じて隣が全面になる。閉じたのが焦点の面なら
  /// 焦点と first responder は残る面へ移る。動いている途中で掴み直しても同じ。
  func testHandleReleaseNearTheEdgeClosesTheFace() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    let handle = tab.group.view.handle
    let y = handle.centerInWindow.y

    handle.mouseDown(with: .mouse(.leftMouseDown, at: handle.centerInWindow, in: wc.window))
    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: NSPoint(x: 20, y: y), in: wc.window))
    handle.mouseUp(with: .mouse(.leftMouseUp, at: NSPoint(x: 20, y: y), in: wc.window))
    XCTAssertEqual(tab.group.faces, .terminalOnly, "端ぎりぎりのエディターは閉じる")
    XCTAssertTrue(wc.window.firstResponder === tab.surface)

    let nearRight = facesWidth(wc) - 20
    handle.mouseDown(with: .mouse(.leftMouseDown, at: handle.centerInWindow, in: wc.window))
    handle.mouseDragged(
      with: .mouse(.leftMouseDragged, at: NSPoint(x: nearRight, y: y), in: wc.window))
    handle.mouseUp(with: .mouse(.leftMouseUp, at: NSPoint(x: nearRight, y: y), in: wc.window))
    XCTAssertEqual(tab.group.faces, FaceLayout(editorRatio: 1, focus: .editor), "端ぎりぎりの端末は閉じる")
    XCTAssertTrue(wc.window.firstResponder === tab.group.view.editor, "焦点は残ったエディターへ")
  }

  /// 継ぎ目を掴んだ瞬間に焦点の面へ first responder が戻り、引いて離しても焦点の面は変わらない。
  func testSeamGrabReturnsFocusToTheFocusedFaceAndDragKeepsIt() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    tab.group.setFaces(FaceLayout(editorRatio: 0.5, focus: .editor), animated: false)
    layout(wc)
    wc.window.makeFirstResponder(nil)
    XCTAssertFalse(wc.window.firstResponder === tab.group.view.editor, "前提: 焦点の面から外れている")
    let handle = tab.group.view.handle
    let grab = handle.centerInWindow
    let offset = grab.x - handle.frame.minX
    let y = grab.y
    let ratio = try XCTUnwrap(FaceGeometry.ratio(hx: 300 - offset, width: facesWidth(wc)))

    handle.mouseDown(with: .mouse(.leftMouseDown, at: grab, in: wc.window))
    XCTAssertTrue(wc.window.firstResponder === tab.group.view.editor, "掴んだ瞬間に焦点の面へ戻る")

    handle.mouseDragged(with: .mouse(.leftMouseDragged, at: NSPoint(x: 300, y: y), in: wc.window))
    handle.mouseUp(with: .mouse(.leftMouseUp, at: NSPoint(x: 300, y: y), in: wc.window))
    XCTAssertEqual(tab.group.faces.focus, .editor, "焦点はエディターのまま")
    XCTAssertEqual(tab.group.faces.editorRatio, ratio, accuracy: 0.0001)
    XCTAssertTrue(wc.window.firstResponder === tab.group.view.editor)
  }

  /// 閾値（4px）未満しか動かさずに離せば押した扱い（隣の面を全開）。
  func testNotchMoveUnderTheThresholdIsAClick() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    let handle = tab.group.view.handle
    let grab = handle.centerInWindow

    handle.mouseDown(with: .mouse(.leftMouseDown, at: grab, in: wc.window))
    handle.mouseDragged(
      with: .mouse(.leftMouseDragged, at: NSPoint(x: grab.x + 3, y: grab.y), in: wc.window))
    handle.mouseUp(with: .mouse(.leftMouseUp, at: NSPoint(x: grab.x + 3, y: grab.y), in: wc.window))

    XCTAssertEqual(tab.group.faces, FaceLayout(editorRatio: 1, focus: .editor), "隠れていたエディターが全開")
    XCTAssertTrue(wc.window.firstResponder === tab.group.view.editor)
  }

  // MARK: - 連ごとの配置と焦点の面

  /// 配置と焦点の面は連が持つ。同じ連の新しいタブへ移っても配置と焦点の面は変わらず、新しい連は端末だけで始まり、
  /// 元の連へ戻ればその配置と焦点の面へ戻る。
  func testLayoutAndFocusedFaceBelongToTheGroup() throws {
    let wc = WindowController()
    let first = try XCTUnwrap(wc.activeTab)
    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertTrue(wc.window.firstResponder === first.group.view.editor, "前提: 連はエディター焦点")

    wc.newTab()
    let sibling = try XCTUnwrap(wc.activeTab)
    XCTAssertTrue(sibling.group === first.group, "前提: 同じ cwd の新タブは同じ連")
    XCTAssertEqual(sibling.group.faces, FaceLayout(editorRatio: 1, focus: .editor), "連の配置のまま")
    XCTAssertTrue(wc.window.firstResponder === first.group.view.editor, "焦点の面も連で共有する")

    wc.openTab(workspaceIndex: wc.activeWorkspace, cwd: TestScratch.caseDir.path)
    let stranger = try XCTUnwrap(wc.activeTab)
    XCTAssertFalse(stranger.group === first.group, "前提: 別の根は別の連")
    XCTAssertEqual(stranger.group.faces, .terminalOnly, "新しい連は端末だけで始まる")
    XCTAssertTrue(wc.window.firstResponder === stranger.surface)

    _ = wc.controlFocusTab(tabId: first.id)
    XCTAssertEqual(first.group.faces, FaceLayout(editorRatio: 1, focus: .editor), "元の連の配置は残る")
    XCTAssertTrue(wc.window.firstResponder === first.group.view.editor, "元の連の焦点の面へ戻る")
  }

  /// ヘルプを閉じると焦点の面（エディター pane）へ戻る。ヘルプの入力欄が first responder を取るのは
  /// SwiftUI の focus 経由で同期には決まらないので、奪われた状態は明示的に作る。
  func testHelpDismissReturnsFocusToTheEditorPane() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    wc.handleWindowCommand(.toggleEditorFace)

    wc.showHelp()
    wc.window.makeFirstResponder(nil)
    XCTAssertFalse(wc.window.firstResponder === tab.group.view.editor, "前提: 焦点はヘルプ側にある")
    wc.dismissHelp()
    pump(0.05)

    XCTAssertTrue(wc.window.firstResponder === tab.group.view.editor)
  }

  /// 制御 API の `focus_tab` もそのタブの焦点の面へ着地する。
  func testControlFocusTabLandsOnTheFocusedFace() throws {
    let wc = WindowController()
    let first = try XCTUnwrap(wc.activeTab)
    wc.handleWindowCommand(.toggleEditorFace)
    wc.newTab()

    _ = wc.controlFocusTab(tabId: first.id)

    XCTAssertTrue(first === wc.activeTab)
    XCTAssertTrue(wc.window.firstResponder === first.group.view.editor)
  }

  /// 復元した連は保存した配置と焦点の面で起き、端末は見えている面の寸法を持つ。
  func testRestoredTabWakesWithItsSavedLayoutAndFocusedFace() throws {
    let wc = try restore(
      [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)],
      groups: [
        GroupState(
          root: GitWorktreeRoot.root(of: "/tmp"),
          faces: FaceLayout(editorRatio: 0.5, focus: .editor))
      ])
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)

    XCTAssertEqual(tab.group.faces, FaceLayout(editorRatio: 0.5, focus: .editor))
    XCTAssertTrue(wc.window.firstResponder === tab.group.view.editor)
    let content = wc.model.content.bounds.size
    XCTAssertGreaterThan(content.width, 0, "前提: content が実サイズを持つ")
    XCTAssertEqual(
      tab.surface.bounds.size,
      FaceGeometry.resolve(tab.group.faces, size: content).frames.terminal.size, "端末は分割後の面の寸法")
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
      CGSize(width: content.width, height: content.height),
      "戻したら今の窓幅で置き直す")
  }

  // MARK: - chrome

  /// 上段の現在地は焦点の面に追従する——端末焦点は cwd、エディター焦点は worktree ルート。
  func testLocationFollowsTheFocusedFace() throws {
    let root = TestScratch.caseDir
      .appendingPathComponent("orbe-faces-\(UUID().uuidString)")
    let src = root.appendingPathComponent("src")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    let wc = try restore(
      [TabState(cwd: src.path, agent: nil, explicitTitle: nil)], rootPath: root.path)

    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.location, [.dim(src.path)], "端末焦点は cwd 1 本（弱く）")

    wc.handleWindowCommand(.toggleEditorFace)
    wc.flushChrome()
    let normalizedRoot = GitWorktreeRoot.normalizedPath(root.path)
    XCTAssertEqual(
      wc.statusModel.location, [.dim(normalizedRoot)], "エディター焦点で文書が無ければ根だけ（dim）")

    let file = src.appendingPathComponent("a.txt")
    try Data("x".utf8).write(to: file)
    try XCTUnwrap(wc.activeTab).group.openFile(file)
    wc.flushChrome()
    XCTAssertEqual(
      wc.statusModel.location, [.dim(normalizedRoot + "/"), .text("src/a.txt")],
      "根の下の文書は根（dim）＋相対パス（text）")

    let outside = TestScratch.caseDir.appendingPathComponent("o.txt")
    try Data("x".utf8).write(to: outside)
    try XCTUnwrap(wc.activeTab).group.openFile(outside)
    wc.flushChrome()
    XCTAssertEqual(
      wc.statusModel.location, [.text(outside.resolvingSymlinksInPath().path)], "根の外の文書は絶対パス 1 本")
  }

  /// 事実 → 表現の写し: `~` 短縮は純粋なパス片にかけてから区切りを足す（短縮が末尾の `/` を落とすため）。
  func testLocationPartsAbbreviateBeforeAddingTheSeparator() {
    let home = NSHomeDirectory()
    XCTAssertEqual(
      StatusRowModel.parts(of: .file(root: home + "/dev", relative: "a/b.swift")),
      [.dim("~/dev/"), .text("a/b.swift")])
    XCTAssertEqual(StatusRowModel.parts(of: .root(home)), [.dim("~")])
    XCTAssertEqual(StatusRowModel.parts(of: .cwd(home + "/x")), [.dim("~/x")])
    XCTAssertEqual(
      StatusRowModel.parts(of: .absolute("/private/var/y")), [.text("/private/var/y")],
      "根の外の文書だけ強く")
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

    tab.group.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.faceDots, .init(editor: .on, terminal: .focus), "分割で端末焦点")

    wc.closeTab(tab, origin: .gesture)
    wc.flushChrome()
    XCTAssertNil(wc.statusModel.faceDots, "0 タブでは無い")
  }
}
