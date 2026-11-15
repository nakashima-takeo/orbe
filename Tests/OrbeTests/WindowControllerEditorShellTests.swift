import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 骨の窓側の結線——サイドバーの記憶は app-state から起きて全連の面へ配られ、どの連で変えても書き戻る。
/// 隠れた連と端末だけの連の面は mount の瞬間にも根のサービスを握らない。開いていた文書は復元で戻り、
/// 未消費の背景の連の分も含めて再保存で同じ形に戻る。見えている面が裏の fetch を欲しがるかは、面の workspace の
/// 実効設定で決まる。
///
/// 壊れると何が起きるか。再起動でサイドバーの幅と開閉が戻らない。起動時の復元で背景の連ぶんの readdir・
/// FSEvents・git が余計に走る。再起動を重ねると一度も見なかった連の文書が消える。自動 fetch をオフにしても
/// 裏の fetch が続き、ssh-agent の承認を毎回求める人に 180 秒ごとに承認の窓が出る。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
@MainActor
final class WindowControllerEditorShellTests: OrbeTestCase {
  override func setUp() {
    super.setUp()
    AppStatePersistence.save(
      AppStateFile(cachedShellPath: "/usr/bin:/bin", preferredLanguage: "ja"))
  }

  private func launch(activeWorkspace: Int = 0, _ workspaces: [WorkspaceState]) -> WindowController
  {
    WorkspacePersistence.save(
      WorkspacesFile(
        version: WorkspacePersistence.version, activeWorkspace: activeWorkspace,
        workspaces: workspaces))
    return WindowController()
  }

  private func caseDirectory(_ name: String) throws -> URL {
    let url = TestScratch.caseDir.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func tab(_ cwd: URL) -> TabState {
    TabState(cwd: cwd.path, agent: nil, explicitTitle: nil)
  }

  private func group(_ root: URL, editor: EditorState) -> GroupState {
    GroupState(root: GitWorktreeRoot.root(of: root.path), editor: editor)
  }

  func testSidebarMemoryComesFromAppStateAndAnyTabWritesItBack() throws {
    AppStatePersistence.update { $0.editorSidebar = EditorSidebarRecord(width: 300, isOpen: false) }
    let one = try caseDirectory("one")
    let two = try caseDirectory("two")
    let wc = launch([
      WorkspaceState(name: "main", rootPath: one.path, activeTab: 0, tabs: [tab(one), tab(two)])
    ])
    let first = try XCTUnwrap(wc.activeTab)
    let second = wc.current.tabs[1]

    XCTAssertEqual(first.group.view.editor.sidebar.width, 300)
    XCTAssertFalse(first.group.view.editor.sidebar.isOpen, "app-state の記憶で起きる")
    XCTAssertTrue(
      first.group.view.editor.sidebar === second.group.view.editor.sidebar, "アプリ全体で 1 つ")

    second.group.view.editor.shell.selectPanel(.files)
    XCTAssertTrue(first.group.view.editor.sidebar.isOpen, "どの連で開いても全連に効く")
    XCTAssertEqual(
      AppStatePersistence.load()?.editorSidebar,
      EditorSidebarRecord(width: 300, isOpen: true, panel: "files", graphHeight: 198),
      "開閉は app-state へ書き戻る")
    XCTAssertEqual(AppStatePersistence.load()?.preferredLanguage, "ja", "他の項目は巻き込まない")
  }

  /// 起動時の mount で、隠れタブも端末だけの可視タブも、面（エクスプローラー）は根のサービスを握らない。
  /// 握れば一覧が取られる（`entries` が埋まる）ので、握っていないことは一覧が空のままであることで見る。
  func testMountingTabsDoesNotLetHiddenOrTerminalOnlyPanesHoldTheRootService() throws {
    let one = try caseDirectory("one")
    let two = try caseDirectory("two")
    let wc = launch([
      WorkspaceState(name: "main", rootPath: one.path, activeTab: 0, tabs: [tab(one), tab(two)])
    ])
    let visible = try XCTUnwrap(wc.activeTab)
    let hidden = wc.current.tabs[1]
    pumpMain(until: { hidden.group.view.superview != nil }, "隠れた連の器が mount される")

    XCTAssertTrue(hidden.group.view.isHidden)
    XCTAssertFalse(hidden.group.view.editor.tree.isLive)
    XCTAssertTrue(hidden.group.view.editor.tree.entries.isEmpty, "隠れた連の面は一度も握っていない")
    XCTAssertFalse(visible.group.view.editor.tree.isLive)
    XCTAssertTrue(
      visible.group.view.editor.tree.entries.isEmpty, "端末だけの可視の連の面も、mount の瞬間に握らない")

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertTrue(visible.group.view.editor.tree.isLive, "面が見えれば握る")
    XCTAssertNotNil(visible.group.view.editor.tree.entries[""], "握れば根の一覧が揃う")
    XCTAssertTrue(hidden.group.view.editor.tree.entries.isEmpty, "隠れた連は変わらず握らない")
  }

  /// 文書を開く・閉じるは構成の変化なので保存が予約され、デバウンスの締切の後にディスクへ書かれる（予約
  /// されなければ再起動で開いていた文書が戻らない）。
  func testOpeningADocumentSchedulesASave() throws {
    let dir = try caseDirectory("w")
    let a = try caseFile("w/a.txt", "a").resolvingSymlinksInPath()
    let wc = launch([
      WorkspaceState(name: "main", rootPath: dir.path, activeTab: 0, tabs: [tab(dir)])
    ])
    wc.flushSave()
    XCTAssertEqual(try XCTUnwrap(WorkspacePersistence.load()).workspaces[0].groups, [])

    try XCTUnwrap(wc.activeTab).group.openFile(a)
    pumpMain(
      until: { WorkspacePersistence.load()?.workspaces[0].groups.first != nil }, timeout: 4,
      "デバウンスの締切をまたいで書かれる")

    XCTAssertEqual(
      try XCTUnwrap(WorkspacePersistence.load()).workspaces[0].groups,
      [group(dir, editor: EditorState(documents: .init(open: [a.path], active: a.path)))])
  }

  /// 保存 → 復元 → 再保存。前面の連の文書は開かれて焦点の文書が面に載り、一度も起きない背景 workspace の
  /// 連の文書は未消費のまま同じ形で書き戻る。
  func testOpenDocumentsRoundTripThroughRestoreAndSave() throws {
    let dir = try caseDirectory("repo")
    let a = try caseFile("repo/a.txt", "a").resolvingSymlinksInPath()
    let b = try caseFile("repo/b.txt", "b").resolvingSymlinksInPath()
    let c = try caseFile("repo/c.txt", "c").resolvingSymlinksInPath()
    let front = EditorState(documents: .init(open: [a.path, b.path], active: b.path))
    let dormant = EditorState(documents: .init(open: [c.path], active: c.path))
    let wc = launch([
      WorkspaceState(
        name: "front", rootPath: dir.path, activeTab: 0, tabs: [tab(dir)],
        groups: [group(dir, editor: front)]),
      WorkspaceState(
        name: "bg", rootPath: dir.path, activeTab: 0, tabs: [tab(dir)],
        groups: [group(dir, editor: dormant)]),
    ])
    let active = try XCTUnwrap(wc.activeTab)
    XCTAssertEqual(active.group.editor.documents.map(\.url), [a, b])
    XCTAssertTrue(
      active.group.view.editor.document === active.group.editor.activeDocument, "焦点の文書が面に載る")
    XCTAssertEqual(active.group.view.editor.document?.url, b)
    XCTAssertEqual(active.group.view.editor.shell.tabs.map(\.name), ["a.txt", "b.txt"])
    XCTAssertTrue(
      wc.workspaces[1].tabs[0].group.editor.documents.isEmpty, "背景 workspace の連は起きない")

    wc.flushSave()
    let saved = try XCTUnwrap(WorkspacePersistence.load())
    XCTAssertEqual(saved.workspaces[0].groups, [group(dir, editor: front)])
    XCTAssertEqual(saved.workspaces[1].groups, [group(dir, editor: dormant)], "未消費の状態を同じ形で書き戻す")
  }

  /// 見えているエディター面は、既定（オン）なら裏の fetch を欲しがり、面の workspace で自動 fetch をオフにするとその場で
  /// 欲しがらなくなる。
  func testTheBackgroundFetchFollowsTheWorkspacesAutoFetchSetting() throws {
    let repo = try TempGitRepo()
    let wc = launch([
      WorkspaceState(name: "main", rootPath: repo.root, activeTab: 0, tabs: [tab(repo.dir)])
    ])
    wc.handleWindowCommand(.toggleEditorFace)
    let scm = try XCTUnwrap(wc.activeTab).group.view.editor.scm
    pumpMain(until: { scm.liveFiles?.repo != nil }, "根の git dir が分かる")
    let autoFetch = ScmAutoFetch.shared(for: try XCTUnwrap(scm.liveFiles?.repo))
    pumpMain(until: { autoFetch.rules.isWanted }, "既定（オン）なら欲しがる")

    wc.applySetting(SettingChange(SettingKeys.scmAutoFetch, false), scope: .workspace)
    XCTAssertFalse(autoFetch.rules.isWanted, "workspace でオフにするとその場で欲しがらない")
  }
}
