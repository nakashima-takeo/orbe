import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 閉じる——ファイルタブの × は焦点を動かさず、連が消えれば（最後のタブが閉じれば）面・ツリー・文書は解放され、
/// 同じ根を握る別の連（別の workspace の同じ worktree）の監視は続く。面が窓に残っても、本体に見せていた diff は連と一緒に
/// 終わる。
///
/// 壊れると何が起きるか。端末で打っている最中に隣の × を押すと打鍵がエディターへ移る。消えた連の面が根の
/// サービスを握り続けて、閉じたはずのリポジトリを監視し続ける（連の数に比例して常時監視が増える）。根のファイルが変わると、
/// 消えた連の diff がそれを受けて解放済みのセッションを読み、落ちる。消えた連の PR の diff のために GitHub を読み続ける。
@MainActor
final class EditorPaneViewCloseTests: OrbeTestCase {
  func testFileTabCloseDoesNotMoveTheFocus() throws {
    let dir = TestScratch.caseDir
    let tab = TerminalTab.alone(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    tab.group.view.addSubview(outsider)
    XCTAssertTrue(window.makeFirstResponder(outsider))
    let a = try tab.group.editor.open(try caseFile("a.txt", "a"), as: .pinned)
    let b = try tab.group.editor.open(try caseFile("b.txt", "b"), as: .pinned)
    XCTAssertTrue(pane.document === b)

    pane.shell.requestClose(b.url)

    XCTAssertTrue(pane.document === a, "焦点の文書を閉じれば隣の文書が見える")
    let responder = try XCTUnwrap(window.firstResponder as? NSView)
    XCTAssertFalse(responder.isDescendant(of: pane), "面の外にあった焦点はそのまま")
  }

  func testReleasingAGroupFreesItsPaneWhileAnotherGroupKeepsTheRootService() throws {
    let repo = try TempGitRepo()
    weak var pane: EditorPaneView?
    weak var tree: FileTree?
    weak var document: EditorDocument?
    weak var service: RootFiles?
    var keeper: TerminalTab? = TerminalTab.alone(
      cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let keeperWindow = hostEditor(try XCTUnwrap(keeper), width: 900)

    try autoreleasepool {
      let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
      let window = hostEditor(tab, width: 900)
      let opened = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
      window.makeFirstResponder(opened.surface.responder)
      pane = tab.group.view.editor
      tree = tab.group.view.editor.tree
      document = opened
      service = RootFiles.shared(for: repo.root)
      XCTAssertNotNil(service, "前提: 2 つの連が同じ根を握っている")
      window.orderOut(nil)
      window.contentView = nil
    }

    pumpMain(until: { pane == nil && tree == nil && document == nil }, "連が消えれば面・ツリー・文書は解放される")
    XCTAssertNotNil(service, "同じ根を握る別の連が居る間、根のサービスは生きている")

    keeper = nil
    keeperWindow.contentView = nil
    pumpMain(until: { service == nil }, "最後の握り手が消えれば根のサービスも解放される")
  }

  /// 連が消えると、面が窓に残っていても、本体に見せていた Changes の diff はセッションと一緒に解放され、面の本体は空になる
  /// （消えたセッションの diff が根のファイルの変化を受け続けない）。
  func testTheChangesDiffGoesWithTheGroupEvenIfThePaneStaysInAWindow() throws {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let window = paneWindow()
    weak var diff: EditorDiff?
    weak var pane: EditorPaneView?
    autoreleasepool {
      let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
      window.contentView = tab.group.view.editor
      pumpMain(until: { tab.group.view.editor.diff != nil }, "前提: 本体に Changes の diff が出る")
      diff = tab.group.view.editor.diff
      pane = tab.group.view.editor
    }
    XCTAssertNil(diff, "diff はセッションと一緒に解放される")
    let shown = try XCTUnwrap(pane, "前提: 面は窓に残る")
    guard case .empty = shown.body else { return XCTFail("面の本体は空") }
  }

  /// 連が消えると、面が窓に残っていても、本体に見せていた PR の diff は PR ごとの状態を見るのをやめる（GitHub を読み続けない）。
  func testThePullRequestDiffStopsWatchingWithTheGroupEvenIfThePaneStaysInAWindow() throws {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
    let repo = try TempGitRepo()
    // worktree の今の PR の問い合わせには答えない（答えが出ると、それと違う PR の diff は閉じられる）。既定のブランチに居ると
    // 問い合わせずに答えが出るので、既定のブランチの名前を別にしておく。
    XCTAssertTrue(
      repo.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"]).isSuccess)
    let silent = PullRequestSource(
      branchPullRequests: { _, _, _ in }, branchExists: { _, _ in }, content: { _, _ in },
      setViewed: { _, _, _, _ in }, review: { _, _ in }, writeReview: { _, _, _, _, _ in })
    _ = BranchPullRequest.shared(for: GitWorktreeRoot.root(of: repo.root), source: silent)
    let state = PullRequestState.shared(
      for: PullRequestState.Key(
        commonDir: repo.root + "/.git", id: try XCTUnwrap(GitHubItemID(repo: "me/r", number: 5))),
      source: silent)
    state.attach(repo: try repo.open(), fetchRemote: nil, headRemote: nil)
    let window = paneWindow()
    try autoreleasepool {
      let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
      tab.group.editor.selectScreen(.pullRequest)
      window.contentView = tab.group.view.editor
      try tab.group.editor.openDiff(
        EditorDiff.Key(root: repo.root, path: "a.txt", kind: .pullRequest(state)))
      XCTAssertTrue(state.isWatched, "前提: 本体に出た PR の diff が PR ごとの状態を見ている")
    }
    XCTAssertFalse(state.isWatched, "PR ごとの状態を見ている者は残らない")
  }

  /// 面だけを載せる窓（テストの終わりに面を外す）。
  private func paneWindow() -> NSWindow {
    let window = OrbeWindowFake(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    addTeardownBlock {
      window.orderOut(nil)
      window.contentView = nil
    }
    return window
  }
}
