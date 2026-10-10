import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 秘書の係を、実 `WindowController`・偽 claude・偽の状態報告（`report_agent` と同じ口）で固定する。頼みは溜めて
/// `secretary.json` に即保存し、秘書のタブ（Home に選ばずに起こす claude）が手が空くたびに 1 件ずつ貼って届ける。
/// 秘書の会話は覚えた会話 ID で戻り、再開できない会話は捨てて新しく起こす。秘書の役割の指示は秘書の会話の起動に
/// だけ添える。
///
/// 壊れると何が起きるか: 頼むたびに人の画面が Home へ飛ぶ。作業中の秘書に頼みが重ねて貼られ、混ざる・失われる。
/// 起動直後の idle を「送った後のターンが終わった」と取り違えて 2 件目を重ねる。秘書のタブを閉じると次の頼みで
/// 前の会話が戻らない。消えた会話を再開し続けて頼みが届かない。Home で動く作業用の agent が秘書を名乗る。
///
/// claude は必ず偽物（`stageFakeAgent`。入力を反響し続ける）。
final class SecretaryTests: OrbeTestCase {
  private let homeId = UUID()

  /// 前面は main（素のタブ 1 枚）、背景に Home（`homeTabs`）。
  private func launch(
    _ file: SecretaryFile? = nil, homeTabs: [TabState] = [], stage: Bool = true
  ) throws -> WindowController {
    if stage { _ = try stageFakeAgent("claude") }
    if let file { SecretaryPersistence.save(file) }
    let home = try XCTUnwrap(HomeFolder.url).path
    let workspaces = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
        WorkspaceState(
          name: "Home", rootPath: home, activeTab: 0, tabs: homeTabs, persistentId: homeId),
      ], homeWorkspaceId: homeId)
    try JSONEncoder().encode(workspaces).write(to: workspacesFile())
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    let wc = WindowController()
    if stage {
      XCTAssertTrue(
        waitUntil(ControlProcess.tabSettleTimeout) {
          wc.agentLauncher.detectedCommands.contains("claude")
        }, "偽 claude が検出されない")
    }
    return wc
  }

  private func homeTabs(_ wc: WindowController) throws -> [TerminalTab] {
    try XCTUnwrap(wc.workspaces.first { $0.persistentId == homeId }).tabs
  }

  private func report(_ wc: WindowController, _ tab: TerminalTab, _ state: String, _ id: String) {
    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: state, sessionId: id))
    wc.flushChrome()
  }

  private func screen(_ tab: TerminalTab) -> String {
    tab.surface.controlReadText(scrollback: true) ?? ""
  }

  /// 画面に `needle` が現れるまで待つ。
  private func waitForScreen(_ tab: TerminalTab, contains needle: String) {
    let seen = waitUntil(ControlProcess.tabSettleTimeout) { self.screen(tab).contains(needle) }
    XCTAssertTrue(seen, "タブに \"\(needle)\" が出ない: \(screen(tab))")
  }

  /// 少し待っても画面に現れない。
  private func assertNeverOnScreen(_ tab: TerminalTab, _ needle: String) {
    XCTAssertFalse(waitUntil(1) { self.screen(tab).contains(needle) }, "まだ届けない: \(needle)")
  }

  // MARK: - 起こして届ける

  func testFirstAskOpensAnUnselectedClaudeInHomeAndDeliversOnlyAfterItsFirstIdle() throws {
    let wc = try launch()
    let front = wc.activeTab?.id

    XCTAssertEqual(try wc.secretary.ask(.text("見積もりを山田さんに送る")), .accepted)

    XCTAssertEqual(wc.current.name, "main", "見ている workspace は変わらない")
    XCTAssertEqual(wc.activeTab?.id, front, "見ているタブは変わらない")
    let tab = try XCTUnwrap(try homeTabs(wc).first, "Home に秘書のタブが起きる")
    let command = try XCTUnwrap(tab.surface.initialCommand)
    XCTAssertTrue(command.contains("--append-system-prompt"), "秘書の役割の指示を添える: \(command)")
    XCTAssertFalse(command.contains("見積もり"), "頼みは起動引数で渡さない")
    XCTAssertEqual(wc.secretary.record.pending.count, 1, "起きるまでは溜める")
    XCTAssertEqual(SecretaryPersistence.load()?.pending.count, 1, "溜めた頼みはすぐ保存する")

    report(wc, tab, "idle", "s-1")

    waitForScreen(tab, contains: "見積もりを山田さんに送る")
    XCTAssertTrue(screen(tab).contains("⌘⇧X から · "), "出どころが見える")
    XCTAssertEqual(wc.secretary.record.pending, [], "届けたら列から外す")
    XCTAssertEqual(SecretaryPersistence.load()?.pending, [], "保存からも外す（再起動で二重に届かない）")
    XCTAssertEqual(SecretaryPersistence.load()?.sessionId, "s-1", "会話 ID を覚える")
  }

  /// 作業中・入力待ちの間の頼みは溜め、送った後のターンが終わる（done）たびに 1 件ずつ届ける。送った直後の idle の
  /// まま（状態が変わっていない）では次を送らない。
  func testAsksWhileBusyAreQueuedAndDeliveredOneAfterEachTurn() throws {
    let wc = try launch()
    _ = try wc.secretary.ask(.text("一件目"))
    let tab = try XCTUnwrap(try homeTabs(wc).first)
    report(wc, tab, "idle", "s-1")
    waitForScreen(tab, contains: "一件目")

    XCTAssertEqual(try wc.secretary.ask(.text("二件目")), .queued, "送った後のターンが終わるまで溜める")
    XCTAssertEqual(try wc.secretary.ask(.text("三件目")), .queued)
    wc.flushChrome()
    assertNeverOnScreen(tab, "二件目")

    report(wc, tab, "working", "s-1")
    report(wc, tab, "waiting", "s-1")
    assertNeverOnScreen(tab, "二件目")
    report(wc, tab, "done", "s-1")
    waitForScreen(tab, contains: "二件目")
    XCTAssertFalse(screen(tab).contains("三件目"), "1 ターンに 1 件")
    XCTAssertEqual(wc.secretary.record.pending.count, 1)

    report(wc, tab, "working", "s-1")
    report(wc, tab, "done", "s-1")
    waitForScreen(tab, contains: "三件目")
  }

  // MARK: - 戻る

  /// 秘書のタブを閉じて頼むと、覚えた会話を新しいタブで再開する（秘書の指示付き）。/clear で会話が替われば新しい会話を覚える。
  func testAClosedSecretaryResumesItsLatestConversation() throws {
    let wc = try launch()
    _ = try wc.secretary.ask(.text("一件目"))
    let first = try XCTUnwrap(try homeTabs(wc).first)
    report(wc, first, "idle", "s-1")
    waitForScreen(first, contains: "一件目")
    report(wc, first, "idle", "s-2")
    XCTAssertEqual(wc.secretary.record.sessionId, "s-2", "/clear の後の会話もそのまま秘書の会話")

    wc.closeTab(first, origin: .gesture)
    wc.flushChrome()
    XCTAssertTrue(try homeTabs(wc).isEmpty, "閉じても勝手に起こし直さない")
    _ = try wc.secretary.ask(.text("二件目"))

    let resumed = try XCTUnwrap(try homeTabs(wc).first)
    let command = try XCTUnwrap(resumed.surface.initialCommand)
    XCTAssertTrue(command.hasPrefix("claude --resume s-2 --append-system-prompt "), command)
  }

  /// 覚えた会話で起こしたタブが会話を報告しないまま閉じたら、その会話を捨てて新しい claude で 1 度だけ起こし直す。
  /// 新しく起こしたタブが同じく閉じても、もう起こし直さない。
  func testAConversationThatCannotResumeIsDroppedAndAFreshSecretaryStartsOnce() throws {
    let wc = try launch(SecretaryFile(version: 1, sessionId: "gone", pending: []))
    _ = try wc.secretary.ask(.text("届けたい"))
    let resumed = try XCTUnwrap(try homeTabs(wc).first)
    XCTAssertTrue(try XCTUnwrap(resumed.surface.initialCommand).hasPrefix("claude --resume gone "))

    wc.closeTab(resumed, origin: .process)
    wc.flushChrome()

    XCTAssertNil(wc.secretary.record.sessionId, "再開できない会話を外す")
    XCTAssertTrue(waitUntil(2) { ((try? self.homeTabs(wc)) ?? []).count == 1 }, "新しい claude を起こす")
    let fresh = try XCTUnwrap(try homeTabs(wc).first)
    XCTAssertFalse(try XCTUnwrap(fresh.surface.initialCommand).contains("--resume"))

    wc.closeTab(fresh, origin: .process)
    wc.flushChrome()
    XCTAssertFalse(waitUntil(1) { !((try? self.homeTabs(wc)) ?? []).isEmpty }, "もう起こし直さない")
    XCTAssertEqual(wc.secretary.record.pending.count, 1, "溜めは残る")
  }

  /// 再起動の後、溜めがあれば検出の後に休眠の秘書のタブだけを選ばずに起こし（秘書の指示付きの再開）、手が空いたら届ける。
  /// Home のほかの休眠のタブ（人が起こした claude）は起こさず、起こしても秘書の指示は添えない。
  func testAfterRelaunchTheDormantSecretaryWakesAloneWithItsInstructions() throws {
    let queued = SecretaryRequest(id: UUID(), receivedAt: Date(), body: "溜めた頼み")
    let wc = try launch(
      SecretaryFile(version: 1, sessionId: "s-1", pending: [queued]),
      homeTabs: [
        TabState(
          cwd: "/tmp", agent: AgentSession(command: "claude", sessionId: "other"),
          explicitTitle: nil),
        TabState(
          cwd: "/tmp", agent: AgentSession(command: "claude", sessionId: "s-1"),
          explicitTitle: nil),
      ])
    let tabs = try homeTabs(wc)
    let (other, secretary) = (tabs[0], tabs[1])
    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) { !secretary.isDormant }, "秘書のタブが起きる")
    XCTAssertTrue(other.isDormant, "ほかのタブは起こさない")
    XCTAssertEqual(wc.current.name, "main", "見ている workspace は変わらない")
    let command = try XCTUnwrap(secretary.surface.initialCommand)
    XCTAssertTrue(command.hasPrefix("claude --resume s-1 --append-system-prompt "), command)

    report(wc, secretary, "idle", "s-1")
    waitForScreen(secretary, contains: "溜めた頼み")

    wc.wakeUnselected(other)
    XCTAssertFalse(
      try XCTUnwrap(other.surface.initialCommand).contains("--append-system-prompt"),
      "秘書の会話でなければ指示を添えない")
  }

  /// 溜めが無ければ、再起動の後も休眠の秘書のタブは起こさない（頼まれるまで起きない）。
  func testAfterRelaunchWithoutQueuedAsksTheDormantSecretaryStaysAsleep() throws {
    let wc = try launch(
      SecretaryFile(version: 1, sessionId: "s-1", pending: []),
      homeTabs: [
        TabState(
          cwd: "/tmp", agent: AgentSession(command: "claude", sessionId: "s-1"),
          explicitTitle: nil)
      ])
    let secretary = try XCTUnwrap(try homeTabs(wc).first)

    wc.flushChrome()

    XCTAssertFalse(waitUntil(1) { !secretary.isDormant }, "頼まれるまで起こさない")
  }

  // MARK: - 受けない

  func testWithoutClaudeTheAskIsRefusedAndNothingIsQueued() throws {
    let wc = try launch(stage: false)

    XCTAssertThrowsError(try wc.secretary.ask(.text("頼み"))) {
      XCTAssertEqual($0 as? Secretary.Refusal, .claudeMissing)
    }
    XCTAssertEqual(wc.secretary.record.pending, [])
    XCTAssertTrue(try homeTabs(wc).isEmpty)
  }
}
