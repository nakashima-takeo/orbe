import AppKit
import XCTest

@testable import Orbe

/// 休眠チケットを 1 枚だけ持つ背景 workspace 付きの駆動台。
/// 分割した拡張ファイル（+StateEmit）からも使うため internal。
struct DormantTicketFixture {
  let wc: WindowController
  let tab: TerminalTab
  let ticket: AgentSession
}

/// `report_agent` が `AgentSlot`（none / dormant / live）へ与える**遷移そのもの**を固定する。
/// 隣の +StateEmit が wire（`agent_state`）を、既存の本体ファイル群が Attention 投影を測るのに対し、
/// ここが測るのは状態機械の帰結——slot・`list_tabs`・`tabState()`・チケット消費の 4 面。
///
/// 壊れると、①偽の報告が未消費の復元チケットを書き換えて resume の鍵（sessionId）が失われる
/// （再起動後に二度と resume できず、しかも `list_tabs` は偽値を返すので呼び手は気づけない）、
/// ②CLI をまたいだ sessionId の生き残りで「codex ＋ claude 由来 id」という resume 不能な組が
/// 永続記録に載る、③消費済みのタブが休眠へ巻き戻り休眠数が二重計上される、のいずれかに倒れる。
///
/// 重要: 本体ファイルと同じく実 NSWindow ＋ 実 libghostty を起動する（ヘッドレスではない）。
extension WindowControllerReportAgentTests {

  // MARK: - fixtures / helpers

  /// アクティブ workspace（素のシェル）＋ **一度も activate していない**背景 workspace（agent タブ 1 枚）で
  /// 起動する。背景側は mount されないのでタブは `.dormant`（未消費チケット）のまま留まる。
  /// 分割した拡張ファイル（+StateEmit）からも使うため internal。
  func makeControllerAndDormantTicket(command: String, sessionId: String) throws
    -> DormantTicketFixture
  {
    let ticket = AgentSession(command: command, sessionId: sessionId)
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
        WorkspaceState(
          name: "sleeping", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/w", agent: ticket, explicitTitle: nil)]),
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    let wc = WindowController()
    let workspace = try XCTUnwrap(wc.workspaces.first { $0.name == "sleeping" })
    XCTAssertFalse(workspace.activated, "前提: 未 activate の workspace はタブを mount しない")
    let tab = try XCTUnwrap(workspace.tabs.first)
    XCTAssertEqual(tab.agentSlot, .dormant(ticket), "前提: 復元直後は未消費のチケット")
    return DormantTicketFixture(wc: wc, tab: tab, ticket: ticket)
  }

  /// `list_tabs` から当該タブの行を引く。
  private func listTabRow(_ wc: WindowController, tabId: Int) -> [String: Any]? {
    wc.controlListTabs().first { $0["tabId"] as? Int == tabId }
  }

  /// 復元単位が持つ agent セッション。cwd は実 surface だと `currentPwd` が入って
  /// 実行環境に依存するため、比べるのは agent だけにする。
  private func snapshotAgent(_ tab: TerminalTab) -> AgentSession? { tab.tabState().agent }

  // MARK: - .dormant × report（破棄）

  /// 休眠チケット宛の報告は完全に破棄される——slot は Equatable で不変のまま、`list_tabs` にも
  /// 偽の CLI 名・sessionId・状態が一切漏れない。dormant タブは surface 未生成で報告主の
  /// プロセスが存在しえないため、届く報告は必ず偽物。
  func testDormantTicketDiscardsForgedReportOnSlotAndListTabs() throws {
    let f = try makeControllerAndDormantTicket(command: "claude", sessionId: "resume-1")

    f.wc.controlReportAgent(
      tab: f.tab,
      report: AgentHookReport(
        agent: "codex", state: "waiting", sessionId: "forged",
        message: AgentMessage(text: "synthetic")))

    XCTAssertEqual(f.tab.agentSlot, .dormant(f.ticket), "報告は破棄され slot は完全に不変")
    let row = try XCTUnwrap(listTabRow(f.wc, tabId: f.tab.id))
    XCTAssertTrue(row["agentState"] is NSNull, "休眠タブに報告状態は載らない")
    XCTAssertEqual(row["agentSessionId"] as? String, "resume-1", "偽の sessionId が resume の鍵を潰さない")
  }

  /// 偽の報告が届いた後でも、チケットは正常に消費されて resume の起動指示になる
  /// （破棄は「無視」であって、チケットを壊すことでも消費を妨げることでもない）。
  func testForgedReportDoesNotStopDormantTicketFromResuming() throws {
    let f = try makeControllerAndDormantTicket(command: "claude", sessionId: "resume-1")
    f.wc.controlReportAgent(
      tab: f.tab, report: AgentHookReport(agent: "codex", state: "working", sessionId: "forged"))

    f.tab.recordMaterializationStarted()

    XCTAssertEqual(
      f.tab.agentSlot, .live(session: f.ticket, report: nil), "チケットの同一性がそのまま live へ移る")
    XCTAssertEqual(
      f.tab.surface.initialCommand, "claude --resume resume-1", "解決した resume 指示が spawn に効く")
    XCTAssertNotNil(
      f.tab.surface.initialEnv["PATH"], "起動環境には PATH が入る（値は login shell の probe 次第なので見ない）")
  }

  // MARK: - .dormant × clear（破棄）

  /// 休眠チケット宛の clear も破棄される。clear が届いても永続記録（tabState の agent）は
  /// チケットのまま残る——ここが壊れると、休眠中の保存でチケットの同一性が消え、休眠数だけが
  /// 残る半壊状態のまま再起動して resume できなくなる。
  func testDormantTicketDiscardsClearAndKeepsTicketOnEveryObservedFace() throws {
    let f = try makeControllerAndDormantTicket(command: "claude", sessionId: "resume-1")

    f.wc.controlReportAgent(tab: f.tab, report: AgentHookReport(agent: "claude", state: "clear"))

    XCTAssertEqual(f.tab.agentSlot, .dormant(f.ticket), "clear も破棄され slot は完全に不変")
    let row = try XCTUnwrap(listTabRow(f.wc, tabId: f.tab.id))
    XCTAssertTrue(row["agentState"] is NSNull)
    XCTAssertEqual(row["agentSessionId"] as? String, "resume-1")
    XCTAssertEqual(snapshotAgent(f.tab), f.ticket, "休眠のままの保存でチケットの同一性が消えない")
  }

  /// resume 非対応 CLI のチケットは、clear を受けた後でも消費で素のシェルへ落ちる
  /// （clear がチケット消費の分岐を狂わせない）。
  func testClearDoesNotDivertUnresolvableTicketFromFallingBackToShell() throws {
    let f = try makeControllerAndDormantTicket(command: "unknown", sessionId: "x")
    f.wc.controlReportAgent(tab: f.tab, report: AgentHookReport(agent: "unknown", state: "clear"))
    XCTAssertEqual(f.tab.agentSlot, .dormant(f.ticket), "clear はチケットを消費も破壊もしない")

    f.tab.recordMaterializationStarted()

    XCTAssertEqual(f.tab.agentSlot, .none, "resume 非対応は消費で素のシェルへ落ちる")
    XCTAssertNil(f.tab.surface.initialCommand, "起動指示は立たない")
  }

  // MARK: - .none × clear（no-op）

  /// 一度も報告のないタブへ clear が届いても何も起きない（SessionEnd の hook が未報告の
  /// タブへ回り込む経路。壊れないことだけが契約）。
  func testClearOnAgentlessTabIsNoOp() throws {
    let (wc, tab) = try makeControllerAndTab()

    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "clear"))

    XCTAssertEqual(tab.agentSlot, .none)
    let row = try XCTUnwrap(listTabRow(wc, tabId: tab.id))
    XCTAssertTrue(row["agentState"] is NSNull)
    XCTAssertTrue(row["agentSessionId"] is NSNull)
  }

  // MARK: - .none × report（live 化と同一性の確立）

  /// 初回報告で live 化し、報告した CLI 名と sessionId が同一性として確立される。確立した同一性は
  /// `list_tabs`（resume の鍵の読み口）と `tabState()`（再起動をまたぐ永続記録）の両方へ届く。
  func testFirstReportEstablishesIdentityAndPersistsIt() throws {
    let (wc, tab) = try makeControllerAndTab()

    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: "working", sessionId: "s-1"))

    let session = AgentSession(command: "claude", sessionId: "s-1")
    XCTAssertEqual(tab.agentSlot.session, session, "報告した CLI 名と sessionId が同一性になる")
    XCTAssertEqual(tab.agentState, "working", "報告が live の report として載る")
    XCTAssertEqual(
      listTabRow(wc, tabId: tab.id)?["agentSessionId"] as? String, "s-1")
    XCTAssertEqual(snapshotAgent(wc.current.tabs[0]), session, "報告由来の同一性も永続記録に載る")
  }

  /// sessionId を運ばない報告でも live 化するが、同一性が未確定なので永続記録には書かない
  /// （resume 不能な死にチケットをディスクへ増やさない）。
  func testFirstReportWithoutSessionIdGoesLiveButPersistsNothing() throws {
    let (wc, tab) = try makeControllerAndTab()

    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "working"))

    XCTAssertEqual(
      tab.agentSlot.session, AgentSession(command: "claude", sessionId: nil), "CLI 名だけが立つ")
    XCTAssertEqual(tab.agentState, "working")
    XCTAssertTrue(listTabRow(wc, tabId: tab.id)?["agentSessionId"] is NSNull)
    XCTAssertNil(snapshotAgent(wc.current.tabs[0]), "sessionId 未確定の同一性は永続化しない")
  }

  // MARK: - 同一性の更新規則（command 常時上書き・sessionId は同一 CLI のあいだ sticky）

  /// sessionId は**同じ CLI からの報告のあいだだけ**引き継がれる。同一 CLI なら運ばない報告でも
  /// 鍵は生き残り、新値が来れば上書きされる。CLI が入れ替わったら旧 id は捨てる——session id は
  /// 発行した CLI に属する値で、他 CLI に付けたまま永続化すると resume 不能な組がディスクに残る。
  func testSessionIdIsStickyWithinOneCliAndDroppedWhenTheCliChanges() throws {
    let (wc, tab) = try makeControllerAndTab()

    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: "working", sessionId: "a"))
    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "claude", state: "waiting"))
    XCTAssertEqual(tab.agentSlot.session?.sessionId, "a", "同一 CLI なら運ばない報告でも鍵は生き残る")
    XCTAssertEqual(listTabRow(wc, tabId: tab.id)?["agentSessionId"] as? String, "a")

    wc.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: "waiting", sessionId: "b"))
    XCTAssertEqual(tab.agentSlot.session?.sessionId, "b", "新値が来れば上書きする")

    // state は直前と同値（同値枝）のまま CLI だけ入れ替える。
    wc.controlReportAgent(tab: tab, report: AgentHookReport(agent: "codex", state: "waiting"))
    XCTAssertEqual(
      tab.agentSlot.session, AgentSession(command: "codex", sessionId: nil),
      "CLI が変われば command を上書きしたうえで旧 id を捨てる")
    XCTAssertTrue(listTabRow(wc, tabId: tab.id)?["agentSessionId"] is NSNull)
    XCTAssertNil(snapshotAgent(wc.current.tabs[0]), "鍵を失った同一性は永続化しない")
  }

  /// 復元 → 消費 → 初回 hook という resume の本線で、チケットの鍵が生き残る。hook は stdin に
  /// session_id が無ければ params ごと省くため、ここで鍵が落ちると次の保存で永続記録が消え、
  /// 再起動後に二度と resume できない。
  func testFirstHookAfterTicketConsumptionKeepsTheResumeKey() throws {
    let f = try makeControllerAndDormantTicket(command: "claude", sessionId: "resume-1")
    f.tab.recordMaterializationStarted()
    XCTAssertEqual(f.tab.agentSlot, .live(session: f.ticket, report: nil), "前提: 消費済み・初回報告前")

    f.wc.controlReportAgent(tab: f.tab, report: AgentHookReport(agent: "claude", state: "working"))

    XCTAssertEqual(f.tab.agentSlot.session, f.ticket, "同一 CLI の初回報告はチケットの鍵を残す")
    XCTAssertEqual(
      listTabRow(f.wc, tabId: f.tab.id)?["agentSessionId"] as? String, "resume-1")
    XCTAssertEqual(snapshotAgent(f.tab), f.ticket, "永続記録も鍵を保つ")
  }

  // MARK: - 禁止遷移（live 化後に .dormant へは戻らない）

  /// チケットの消費はワンショット。消費後は clear でも再報告でも `.dormant` へ巻き戻らず、
  /// 休眠数は 0 のまま——巻き戻れば同じチケットが二度数えられ、パレットの休眠件数が嘘になる。
  func testConsumedTicketNeverReturnsToDormant() throws {
    let f = try makeControllerAndDormantTicket(command: "claude", sessionId: "resume-1")
    let workspace = try XCTUnwrap(f.wc.workspaces.first { $0.name == "sleeping" })
    XCTAssertEqual(workspace.dormantAgentCount(), 1, "前提: 未消費のチケットが 1 枚")

    f.tab.recordMaterializationStarted()
    XCTAssertEqual(workspace.dormantAgentCount(), 0, "前提: 消費で休眠から外れる")

    f.wc.controlReportAgent(tab: f.tab, report: AgentHookReport(agent: "claude", state: "working"))
    f.wc.controlReportAgent(tab: f.tab, report: AgentHookReport(agent: "claude", state: "clear"))
    XCTAssertEqual(f.tab.agentSlot, .none, "clear は無へ戻す（休眠へは戻さない）")
    XCTAssertEqual(workspace.dormantAgentCount(), 0)

    f.wc.controlReportAgent(
      tab: f.tab, report: AgentHookReport(agent: "claude", state: "working", sessionId: "new"))
    XCTAssertEqual(
      f.tab.agentSlot.session, AgentSession(command: "claude", sessionId: "new"),
      "再報告は休眠を経ずに live 化する")
    XCTAssertEqual(workspace.dormantAgentCount(), 0)
  }
}
