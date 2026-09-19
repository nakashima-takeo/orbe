import AppKit
import XCTest

@testable import Orbe

/// 骨の窓側の結線——サイドバーの記憶は app-state から起きて全タブの面へ配られ、どのタブで変えても書き戻る。
/// 隠れタブと端末だけのタブの面は mount の瞬間にも根のサービスを握らない。開いていた文書は復元で戻り、
/// 未消費の背景タブの分も含めて再保存で同じ形に戻る。
///
/// 壊れると何が起きるか。再起動でサイドバーの幅と開閉が戻らない。起動時の復元で背景タブぶんの readdir・
/// FSEvents・git が余計に走る。再起動を重ねると一度も見なかったタブの文書が消える。
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
    let url = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func tab(_ cwd: URL, editor: EditorState? = nil) -> TabState {
    TabState(cwd: cwd.path, agent: nil, explicitTitle: nil, editor: editor)
  }

  func testSidebarMemoryComesFromAppStateAndAnyTabWritesItBack() throws {
    AppStatePersistence.update { $0.editorSidebar = EditorSidebarRecord(width: 300, isOpen: false) }
    let dir = try caseDirectory("w")
    let wc = launch([
      WorkspaceState(name: "main", rootPath: dir.path, activeTab: 0, tabs: [tab(dir), tab(dir)])
    ])
    let first = try XCTUnwrap(wc.activeTab)
    let second = wc.current.tabs[1]

    XCTAssertEqual(first.view.editor.sidebar.width, 300)
    XCTAssertFalse(first.view.editor.sidebar.isOpen, "app-state の記憶で起きる")
    XCTAssertTrue(first.view.editor.sidebar === second.view.editor.sidebar, "アプリ全体で 1 つ")

    second.view.editor.shell.toggleSidebar()
    XCTAssertTrue(first.view.editor.sidebar.isOpen, "どのタブで開いても全タブに効く")
    XCTAssertEqual(
      AppStatePersistence.load()?.editorSidebar, EditorSidebarRecord(width: 300, isOpen: true),
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
    pumpMain(until: { hidden.view.superview != nil }, "隠れタブが mount される")

    XCTAssertTrue(hidden.view.isHidden)
    XCTAssertFalse(hidden.view.editor.tree.isLive)
    XCTAssertTrue(hidden.view.editor.tree.entries.isEmpty, "隠れタブの面は一度も握っていない")
    XCTAssertFalse(visible.view.editor.tree.isLive)
    XCTAssertTrue(visible.view.editor.tree.entries.isEmpty, "端末だけの可視タブの面も、mount の瞬間に握らない")

    wc.handleWindowCommand(.toggleEditorFace)
    XCTAssertTrue(visible.view.editor.tree.isLive, "面が見えれば握る")
    XCTAssertNotNil(visible.view.editor.tree.entries[""], "握れば根の一覧が揃う")
    XCTAssertTrue(hidden.view.editor.tree.entries.isEmpty, "隠れタブは変わらず握らない")
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
    XCTAssertNil(try XCTUnwrap(WorkspacePersistence.load()).workspaces[0].tabs[0].editor)

    try XCTUnwrap(wc.activeTab).openFile(a)
    pumpMain(
      until: { WorkspacePersistence.load()?.workspaces[0].tabs[0].editor != nil }, timeout: 4,
      "デバウンスの締切をまたいで書かれる")

    XCTAssertEqual(
      try XCTUnwrap(WorkspacePersistence.load()).workspaces[0].tabs[0].editor,
      EditorState(open: [a.path], active: a.path))
  }

  /// 保存 → 復元 → 再保存。前面のタブの文書は開かれて焦点の文書が面に載り、一度も起きない背景 workspace の
  /// タブの文書は未消費のまま同じ形で書き戻る。
  func testOpenDocumentsRoundTripThroughRestoreAndSave() throws {
    let dir = try caseDirectory("repo")
    let a = try caseFile("repo/a.txt", "a").resolvingSymlinksInPath()
    let b = try caseFile("repo/b.txt", "b").resolvingSymlinksInPath()
    let c = try caseFile("repo/c.txt", "c").resolvingSymlinksInPath()
    let front = EditorState(open: [a.path, b.path], active: b.path)
    let dormant = EditorState(open: [c.path], active: c.path)
    let wc = launch([
      WorkspaceState(
        name: "front", rootPath: dir.path, activeTab: 0, tabs: [tab(dir, editor: front)]),
      WorkspaceState(
        name: "bg", rootPath: dir.path, activeTab: 0, tabs: [tab(dir, editor: dormant)]),
    ])
    let active = try XCTUnwrap(wc.activeTab)
    XCTAssertEqual(active.editor.documents.map(\.url), [a, b])
    XCTAssertTrue(active.view.editor.document === active.editor.activeDocument, "焦点の文書が面に載る")
    XCTAssertEqual(active.view.editor.document?.url, b)
    XCTAssertEqual(active.view.editor.shell.tabs.map(\.name), ["a.txt", "b.txt"])
    XCTAssertTrue(wc.workspaces[1].tabs[0].editor.documents.isEmpty, "背景 workspace のタブは起きない")

    wc.flushSave()
    let saved = try XCTUnwrap(WorkspacePersistence.load())
    XCTAssertEqual(saved.workspaces[0].tabs[0].editor, front)
    XCTAssertEqual(saved.workspaces[1].tabs[0].editor, dormant, "未消費の状態を同じ形で書き戻す")
  }
}
