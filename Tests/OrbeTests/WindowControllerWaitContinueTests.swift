import AppKit
import Darwin
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 解けた待ちの ⌘T（続きから）が、条件を付けた agent の会話へ起きたことを届ける振り分け——開いたままの会話のタブ
/// （入力を受けられる／受けられない）、休眠のタブ、タブが無い。届いたかは、タブの PTY や再開した CLI の引数で見る。
///
/// 壊れると何が起きるか: 手で起こした codex が去った後のシェルや作業中の agent に、外の人が書いた確認の出力が貼り付け
/// られて実行される。休眠のタブを起こしても、新しいタブで再開しても、起きたことが会話に届かない。同じ会話が 2 つの
/// タブで同時に動く。消えた作業ディレクトリで再開を試み、起きたことだけが失われる。
///
/// 再開の CLI は必ず偽物（`stageFakeAgent`）にする。
final class WindowControllerWaitContinueTests: OrbeTestCase {
  private let conversationWorkspace = UUID()

  /// 前面の workspace（素のタブ）と、会話を記録した workspace（`tabs`）。
  private func launch(_ tabs: [TabState]) throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
        WorkspaceState(
          name: "conversation", rootPath: "/tmp", activeTab: 0, tabs: tabs,
          persistentId: conversationWorkspace),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    return WindowController()
  }

  private func directory() throws -> String {
    let url = TestScratch.caseDir.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
  }

  /// claude の会話 s-1 が付けた条件を、`output` を出して満たした状態にする。
  @discardableResult
  private func resolved(
    _ wc: WindowController, directory: String?, workspace: UUID? = nil, output: String = ""
  ) throws -> Int {
    var draft = TaskDraft(title: "設定の検索を速くする")
    draft.waitingReason = "レビュー待ち"
    draft.waitingCondition = WaitConditionRequest(
      description: "PR-214-reviewed", command: "exit 1", everyMinutes: 10,
      deadline: Date().addingTimeInterval(3600), directory: directory,
      conversation: WaitConversation(
        command: "claude", sessionId: "s-1", workspace: workspace, secretary: false))
    let task = try wc.taskStore.add(draft)
    let now = Date()
    wc.taskStore.recordCheck(
      task.id, condition: try XCTUnwrap(task.waiting?.condition?.id),
      BackgroundRunResult(
        commandLine: "exit 1", startedAt: now, endedAt: now, ending: .exited(0),
        output: .command(stdout: .init(data: Data(output.utf8)), stderr: .init())))
    XCTAssertNotNil(wc.taskStore.tasks.first { $0.id == task.id }?.waitResolution, "前提: 解けている")
    return task.id
  }

  private func deliver(_ wc: WindowController, _ id: Int) -> TaskPaletteError? {
    wc.refreshChrome()
    wc.flushChrome()
    return wc.continueWait(taskId: id)
  }

  private func resolution(_ wc: WindowController, _ id: Int) -> WaitResolution? {
    wc.taskStore.tasks.first { $0.id == id }?.waitResolution
  }

  private func conversationTabs(_ wc: WindowController) throws -> [TerminalTab] {
    try XCTUnwrap(wc.workspaces.first { $0.persistentId == conversationWorkspace }?.tabs)
  }

  private func waitForDetection(_ wc: WindowController) {
    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) {
        wc.agentLauncher.detectedCommands.contains("claude")
      }, "偽 claude が検出されない")
  }

  private func waitForScreen(_ tab: TerminalTab, contains needle: String) -> String {
    var text = ""
    let seen = waitUntil(ControlProcess.tabSettleTimeout) {
      text = tab.surface.controlReadText(scrollback: true) ?? ""
      return text.contains(needle)
    }
    XCTAssertTrue(seen, "タブに \"\(needle)\" が出ない: \(text)")
    return text
  }

  // MARK: - 開いたままの会話のタブ

  func testOpenConversationThatCanTakeInputGetsWhatHappenedAndEnter() throws {
    let dump = try dump(.legacy)
    let wc = dump.controller
    let id = try resolved(wc, directory: nil)
    wc.controlReportAgent(
      tab: dump.tab, report: AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))
    let input = WaitContinueText.firstInput(
      try XCTUnwrap(resolution(wc, id)), l10n: wc.localization, timeZone: .current)

    XCTAssertNil(deliver(wc, id))

    XCTAssertEqual(dump.next(bytes: input.utf8.count + 1), TtyDumpTab.hex(input + "\r"))
    XCTAssertNil(wc.taskStore.tasks.first { $0.id == id }?.wait, "届けたら起きたことは消える")
  }

  /// 作業中・確認待ちの agent や、Ctrl+Z で止めた agent には何も送らず、移るだけ。
  func testBusyOrStoppedConversationGetsNothingAndKeepsWhatHappened() throws {
    let dump = try dump(.legacy)
    let wc = dump.controller
    let id = try resolved(wc, directory: nil)

    for state in ["working", "waiting"] {
      wc.controlReportAgent(
        tab: dump.tab, report: AgentHookReport(agent: "claude", state: state, sessionId: "s-1"))
      XCTAssertNil(deliver(wc, id))

      dump.tab.surface.controlSendText("x")
      XCTAssertEqual(dump.next(), TtyDumpTab.hex("x"), "\(state): 目印より先に何も届いていない")
      XCTAssertNotNil(resolution(wc, id), "\(state): 起きたことは残る（もう一度 ⌘T を押せる）")
    }

    wc.controlReportAgent(
      tab: dump.tab, report: AgentHookReport(agent: "claude", state: "idle", sessionId: "s-1"))
    let group = try XCTUnwrap(dump.tab.surface.foregroundProcessGroup)
    kill(-group, SIGSTOP)
    XCTAssertTrue(waitUntil { !ProcessGroup.isRunning(group) }, "前提: 止まる")
    XCTAssertNil(deliver(wc, id))
    kill(-group, SIGCONT)

    dump.tab.surface.controlSendText("x")
    XCTAssertEqual(dump.next(), TtyDumpTab.hex("x"), "止まっている間に何も届いていない")
    XCTAssertNotNil(resolution(wc, id), "起きたことは残る")
  }

  /// 確認の出力の制御文字（改行・タブ以外）は、会話へ届ける前に空白にする（起動引数の NUL が再開を壊さない）。
  func testWhatHappenedReachesTheConversationWithoutControlCharacters() throws {
    let dump = try dump(.legacy)
    let id = try resolved(dump.controller, directory: nil, output: "a\u{0}b\u{1b}[31mc\td\ne")
    let input = WaitContinueText.firstInput(
      try XCTUnwrap(resolution(dump.controller, id)), l10n: dump.controller.localization,
      timeZone: .current)

    XCTAssertTrue(input.hasSuffix("a b [31mc\td\ne"), input)
  }

  // MARK: - 休眠のタブ

  func testDormantConversationTabWakesWithWhatHappenedAsItsFirstInput() throws {
    let fake = try stageFakeAgent("claude")
    let dir = try directory()
    let wc = try launch([
      TabState(
        cwd: dir, agent: AgentSession(command: "claude", sessionId: "s-1"), explicitTitle: nil)
    ])
    let dormant = try XCTUnwrap(try conversationTabs(wc).first)
    XCTAssertTrue(dormant.isDormant, "前提: 会話のタブは休眠のまま")
    let id = try resolved(wc, directory: dir, output: "LGTM")

    XCTAssertNil(deliver(wc, id))

    let screen = waitForScreen(dormant, contains: fake.marker)
    XCTAssertTrue(screen.contains("\(fake.marker) --resume s-1 "), "同じ会話を再開する: \(screen)")
    XCTAssertTrue(
      screen.contains("PR-214-reviewed") && screen.contains("LGTM"),
      "再開の最初の入力に起きたことが入る: \(screen)")
    XCTAssertEqual(try conversationTabs(wc).map(\.id), [dormant.id], "新しいタブは開かない")
    XCTAssertNil(resolution(wc, id), "届けたら起きたことは消える")
  }

  // MARK: - タブが無い

  /// ⌘⇧X で選んだ解けたタスクの ⌘T が、worktree パレットを開かず、条件を付けたタブの workspace と作業ディレクトリで
  /// 会話を再開する（前面の workspace ではない）。
  func testCommandTWithoutAConversationTabResumesItWhereTheConditionWasSet() throws {
    let fake = try stageFakeAgent("claude")
    let dir = try directory()
    let wc = try launch([TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
    waitForDetection(wc)
    let id = try resolved(wc, directory: dir, workspace: conversationWorkspace, output: "LGTM")
    let before = try conversationTabs(wc).map(\.id)
    XCTAssertTrue(wc.handleWindowKeyCommand(.showTaskPalette))
    let palette = try XCTUnwrap(wc.model.taskPalette)
    palette.reconcile()
    XCTAssertEqual(palette.selectedID, .task(id), "前提: 解けたタスクを選んでいる")

    palette.openWorktreePalette()

    XCTAssertNotEqual(wc.presentedOverlay, .worktreePalette, "worktree パレットは開かない")
    let opened = try XCTUnwrap(
      try conversationTabs(wc).first { !before.contains($0.id) }, "記録した workspace に新しいタブが開く")
    XCTAssertEqual(opened.cwd, dir)
    let screen = waitForScreen(opened, contains: fake.marker)
    XCTAssertTrue(screen.contains("\(fake.marker) --resume s-1 "), "同じ会話を再開する: \(screen)")
    XCTAssertTrue(
      screen.contains("PR-214-reviewed") && screen.contains("LGTM"),
      "再開の最初の入力に起きたことが入る: \(screen)")
    XCTAssertNil(resolution(wc, id), "届けたら起きたことは消える")
  }

  /// 同じ会話の続きからを続けて押しても、2 つ目は開いたタブを見つける（同じ会話のタブを 2 つ開かない）。
  func testSecondContinueOfTheSameConversationFindsTheTabJustOpened() throws {
    _ = try stageFakeAgent("claude")
    let dir = try directory()
    let wc = try launch([TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
    waitForDetection(wc)
    let first = try resolved(wc, directory: dir, workspace: conversationWorkspace)
    let second = try resolved(wc, directory: dir, workspace: conversationWorkspace)
    let before = try conversationTabs(wc).count

    XCTAssertNil(wc.continueWait(taskId: first))
    XCTAssertNil(wc.continueWait(taskId: second))

    XCTAssertEqual(try conversationTabs(wc).count, before + 1, "開くのは 1 つだけ")
  }

  /// 続きから始められない（作業ディレクトリが無い）タスクの ⌘T は、いつもの ⌘T（worktree パレット）を開き、タブは
  /// 開かず、起きたことも残す。
  func testCommandTOfAConversationThatCannotContinueOpensTheUsualWorktreePalette() throws {
    _ = try stageFakeAgent("claude")
    let wc = try launch([TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
    waitForDetection(wc)
    let gone = TestScratch.caseDir.appendingPathComponent("gone").path
    let id = try resolved(wc, directory: gone, workspace: conversationWorkspace)
    let before = wc.workspaces.map { $0.tabs.map(\.id) }
    XCTAssertEqual(wc.continuationBlock(taskId: id), .directoryMissing)
    XCTAssertTrue(wc.handleWindowKeyCommand(.showTaskPalette))
    let palette = try XCTUnwrap(wc.model.taskPalette)
    palette.reconcile()
    XCTAssertEqual(palette.selectedID, .task(id), "前提: 解けたタスクを選んでいる")

    palette.openWorktreePalette()

    XCTAssertEqual(wc.presentedOverlay, .worktreePalette, "いつもの ⌘T")
    XCTAssertEqual(wc.workspaces.map { $0.tabs.map(\.id) }, before, "タブは開かない")
    XCTAssertNotNil(resolution(wc, id), "起きたことは残る")
  }
}
