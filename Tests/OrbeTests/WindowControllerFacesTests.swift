import AppKit
import OrbeSessionLog
import OrbeTestSupport
import XCTest

@testable import Orbe

/// エディターの開閉を実窓で固定する——⌘E の往復と焦点、開閉で端末の寸法が変わらないこと、タブを選ぶ操作でエディターが
/// 閉じること（選んでいないタブの増減では閉じない）、⌘⇧F・`focus_tab`・workspace の切替、開閉を保存しないこと、⌘W の
/// 発火源、chrome への投影（現在地）。
///
/// 壊れると何が起きるか。⌘E が見せている面へ first responder を運ばないとキーが隠れた面へ届く。開閉で端末が resize されると
/// scrollback が折り返し直される。タブを選んでもエディターが閉じないと、選んだタブの端末が見えない。裏のタブが閉じただけで
/// エディターが閉じると、読んでいた文書が消える。閉じて開き直したときに文書が戻らないと、⌘E のたびに開き直す手間が生じる。
/// ⌘W の発火源が `.gesture` でなくなると寿命ログが人の操作を「落ちた」と記録し、⇧⌘T のバッジと `orb session closed` の
/// 群れ分けが狂う。chrome が見せているものを映さないと現在地が実態と別の面を指す。
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
    try restore([
      WorkspaceState(name: "main", rootPath: rootPath, activeTab: 0, tabs: tabs, groups: groups)
    ])
  }

  private func restore(_ workspaces: [WorkspaceState]) throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0, workspaces: workspaces)
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  private static let plain = TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)

  func pump(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
  }

  func layout(_ wc: WindowController) {
    wc.window.contentView?.layoutSubtreeIfNeeded()
  }

  /// 器の開閉の動きが終わるまで待つ。
  private func settle(_ tab: TerminalTab) {
    pumpMain(until: { !tab.group.view.isFading }, timeout: 2, "開閉の動きが終わる")
  }

  // MARK: - ⌘E

  /// ⌘E で選んでいるタブのエディターが開き、もう一度で閉じる。first responder も見せている面へ移る。
  func testToggleEditorFaceOpensAndClosesTheEditorAndMovesFocus() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertTrue(tab.group.view.isEditorOpen)
    XCTAssertTrue(
      wc.window.firstResponder === tab.group.view.editor, "エディター pane が first responder")
    settle(tab)
    XCTAssertTrue(tab.terminal.isHiddenOrHasHiddenAncestor, "開き終われば下の端末を描かない")

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertFalse(tab.group.view.isEditorOpen)
    XCTAssertTrue(wc.window.firstResponder === tab.surface, "端末 surface へ戻る")
    settle(tab)
    XCTAssertTrue(tab.group.view.editor.isHiddenOrHasHiddenAncestor)
  }

  /// 開閉で端末の寸法は変わらず、開いている間の窓の resize には覆われた端末も追従する。
  func testOpeningAndClosingNeverResizesTheTerminal() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    layout(wc)
    let size = tab.surface.bounds.size
    XCTAssertGreaterThan(size.width, 0, "前提: 端末が実サイズを持つ")

    wc.handleWindowCommand(.toggleEditorFace)
    settle(tab)
    layout(wc)
    XCTAssertEqual(tab.surface.bounds.size, size, "開いても変わらない")

    wc.window.setContentSize(NSSize(width: 1000, height: 600))
    layout(wc)
    let content = wc.model.content.bounds.size
    XCTAssertEqual(tab.surface.bounds.size, content, "覆われている間も窓の resize に追従する")

    wc.handleWindowCommand(.toggleEditorFace)
    settle(tab)
    layout(wc)
    XCTAssertEqual(tab.surface.bounds.size, content, "閉じても変わらない")
  }

  /// ⌘⇧F は閉じていれば開き、検索欄に焦点を入れる。
  func testFindInProjectOpensTheEditor() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)

    wc.handleWindowCommand(.findInProject)

    XCTAssertTrue(tab.group.view.isEditorOpen)
    XCTAssertEqual(MainActor.assumeIsolated { wc.editorSidebar.panel }, .search)
  }

  // MARK: - タブを選ぶとエディターは閉じる

  /// タブ行のクリック（今のタブを含む）・巡回のキー・新しいタブは、エディターを閉じてそのタブの端末を出す。閉じても文書は
  /// 連に残り、⌘E で開き直せば元の文書が出る。
  @MainActor
  func testSelectingATabClosesTheEditorAndKeepsItsDocuments() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    let document = try tab.group.editor.open(try caseFile("a.txt", "a"), as: .pinned)
    let reopen = {
      wc.handleWindowCommand(.toggleEditorFace)
      XCTAssertTrue(tab.group.view.isEditorOpen)
    }

    reopen()
    wc.select(0)
    XCTAssertFalse(tab.group.view.isEditorOpen, "今のタブのクリックで閉じる")
    XCTAssertTrue(wc.window.firstResponder === tab.surface)

    reopen()
    XCTAssertTrue(tab.group.view.editor.document === document, "開き直すと元の文書")
    wc.newTab()
    let sibling = try XCTUnwrap(wc.activeTab)
    XCTAssertTrue(sibling.group === tab.group, "前提: 同じ連")
    XCTAssertFalse(tab.group.view.isEditorOpen, "新しいタブは端末で出る")
    XCTAssertTrue(wc.window.firstResponder === sibling.surface)

    reopen()
    wc.prevTab()
    XCTAssertTrue(wc.activeTab === tab)
    XCTAssertFalse(tab.group.view.isEditorOpen, "巡回のキーで閉じる")
    XCTAssertTrue(wc.window.firstResponder === tab.surface)
  }

  /// 見ているタブを閉じれば隣のタブの端末が出る。選んでいないタブが閉じても・裏で増えても、エディターのまま。
  func testOnlyClosingTheShownTabClosesTheEditor() throws {
    let wc = try restore([Self.plain, Self.plain, Self.plain])
    let (a, b, c) = (wc.current.tabs[0], wc.current.tabs[1], wc.current.tabs[2])
    wc.toggleEditorFace()

    wc.closeTab(c, origin: .gesture)
    XCTAssertTrue(a.group.view.isEditorOpen, "選んでいないタブが閉じてもエディターのまま")

    wc.openTab(workspaceIndex: wc.activeWorkspace, cwd: "/tmp", selects: false)
    XCTAssertTrue(a.group.view.isEditorOpen, "選ばずに足したタブではエディターのまま")

    wc.closeTab(a, origin: .gesture)
    XCTAssertTrue(wc.activeTab === b)
    XCTAssertFalse(b.group.view.isEditorOpen, "見ているタブを閉じれば隣の端末")
    XCTAssertTrue(wc.window.firstResponder === b.surface)
  }

  /// `focus_tab`（Attention・メニューバー・タスク画面も通る）は、エディターを閉じてそのタブの端末へ焦点を移す。
  func testControlFocusTabLandsOnTheTerminal() throws {
    let wc = WindowController()
    let first = try XCTUnwrap(wc.activeTab)
    wc.handleWindowCommand(.toggleEditorFace)

    _ = wc.controlFocusTab(tabId: first.id)

    XCTAssertTrue(first === wc.activeTab)
    XCTAssertFalse(first.group.view.isEditorOpen)
    XCTAssertTrue(wc.window.firstResponder === first.surface)
  }

  /// workspace を切り替えると、その workspace で選んでいるタブの端末が出る。戻っても端末で出る。
  func testSwitchingWorkspacesShowsTheTerminal() throws {
    let wc = try restore([
      WorkspaceState(name: "a", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain]),
      WorkspaceState(name: "b", rootPath: "/tmp", activeTab: 0, tabs: [Self.plain]),
    ])
    let a = try XCTUnwrap(wc.activeTab)
    wc.toggleEditorFace()

    wc.switchWorkspace(to: 1)
    let b = try XCTUnwrap(wc.activeTab)
    XCTAssertFalse(b.group.view.isEditorOpen)
    XCTAssertFalse(a.group.view.isEditorOpen, "content から外れた器は閉じている")
    XCTAssertTrue(wc.window.firstResponder === b.surface)

    wc.switchWorkspace(to: 0)
    XCTAssertFalse(a.group.view.isEditorOpen)
    XCTAssertTrue(wc.window.firstResponder === a.surface)
  }

  /// ヘルプを閉じると見せている面（エディター pane）へ戻り、エディターは開いたまま。ヘルプの入力欄が first responder を
  /// 取るのは SwiftUI の focus 経由で同期には決まらないので、奪われた状態は明示的に作る。
  func testHelpDismissReturnsFocusToTheEditorPane() throws {
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)
    wc.handleWindowCommand(.toggleEditorFace)

    wc.showHelp()
    wc.window.makeFirstResponder(nil)
    XCTAssertFalse(wc.window.firstResponder === tab.group.view.editor, "前提: 焦点はヘルプ側にある")
    wc.dismissHelp()
    pump(0.05)

    XCTAssertTrue(tab.group.view.isEditorOpen)
    XCTAssertTrue(wc.window.firstResponder === tab.group.view.editor)
  }

  // MARK: - 開閉は保存しない

  /// 分割の割合を保存していた旧い記録から起動しても、連は端末で起き、開いていた文書は ⌘E で戻る。
  @MainActor
  func testAnOldRecordWithFacesWakesClosedWithItsDocuments() throws {
    let file = try caseFile("a.txt", "a")
    let root = GitWorktreeRoot.root(of: TestScratch.caseDir.path)
    let json = """
      {"version":\(WorkspacePersistence.version),"activeWorkspace":0,"workspaces":[\
      {"name":"main","rootPath":"/tmp","activeTab":0,"tabs":[{"cwd":"\(TestScratch.caseDir.path)"}],\
      "groups":[{"root":"\(root)","faces":{"editorRatio":0.5,"focus":"editor"},\
      "editor":{"open":["\(file.path)"],"active":"\(file.path)"}}]}]}
      """
    try Data(json.utf8).write(to: workspacesFile())
    let wc = WindowController()
    let tab = try XCTUnwrap(wc.activeTab)

    XCTAssertFalse(tab.group.view.isEditorOpen, "端末で起きる")
    XCTAssertTrue(wc.window.firstResponder === tab.surface)

    wc.toggleEditorFace()
    XCTAssertEqual(
      tab.group.view.editor.document?.url.resolvingSymlinksInPath(), file.resolvingSymlinksInPath(),
      "開いていた文書が戻る")
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

  // MARK: - chrome

  /// 上段の現在地は見せているものに追従する——端末は cwd、エディターは worktree ルートの下の位置。
  func testLocationFollowsWhatIsShown() throws {
    let root = TestScratch.caseDir
      .appendingPathComponent("orbe-faces-\(UUID().uuidString)")
    let src = root.appendingPathComponent("src")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    let wc = try restore(
      [TabState(cwd: src.path, agent: nil, explicitTitle: nil)], rootPath: root.path)

    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.location, [.dim(src.path)], "端末は cwd 1 本（弱く）")

    wc.handleWindowCommand(.toggleEditorFace)
    wc.flushChrome()
    let normalizedRoot = GitWorktreeRoot.normalizedPath(root.path)
    XCTAssertEqual(
      wc.statusModel.location, [.dim(normalizedRoot)], "エディターで文書が無ければ根だけ（dim）")

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

  /// 事実 → 表現の写し: PR の diff は `PR #N · ディレクトリ/ファイル名`。根の直下のファイルはディレクトリの断片を出さない。
  func testPullRequestLocationPartsSplitTheDirectoryAndTheName() {
    XCTAssertEqual(
      StatusRowModel.parts(of: .pullRequest(number: 9, relative: "src/a/b.swift")),
      [.accent("PR #9"), .dim(" · "), .dim("src/a/"), .text("b.swift")])
    XCTAssertEqual(
      StatusRowModel.parts(of: .pullRequest(number: 9, relative: "README.md")),
      [.accent("PR #9"), .dim(" · "), .text("README.md")])
  }
}
