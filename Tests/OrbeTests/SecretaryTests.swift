import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 秘書の係を、実 `WindowController`・偽 claude で固定する。頼みのたびに、出どころの役目の指示と頼みの本文を起動の
/// 引数にして Home に claude を 1 つ起こし、Home へ移ってそのタブを選ぶ。
///
/// 壊れると何が起きるか: ⌘↵ で任せたのに ⌘⇧X が開いたままで、起きた claude が見えない。ボードの依頼でタスクを足す役目の
/// claude が起きる。頼みが 1 本の会話に混ざる。claude が無いのに打った文が消える。
///
/// claude は必ず偽物（`stageFakeAgent`。入力を反響し続ける）。
final class SecretaryTests: OrbeTestCase {
  let homeId = UUID()

  /// 前面は main（素のタブ 1 枚）、背景に Home（`homeTabs`）。
  func launch(stage: Bool = true) throws -> WindowController {
    if stage { _ = try stageFakeAgent("claude") }
    let home = try XCTUnwrap(HomeFolder.url).path
    let workspaces = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)]),
        WorkspaceState(
          name: "Home", rootPath: home, activeTab: 0, tabs: [], persistentId: homeId),
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

  func homeTabs(_ wc: WindowController) throws -> [TerminalTab] {
    try XCTUnwrap(wc.workspaces.first { $0.persistentId == homeId }).tabs
  }

  // MARK: - 起こす

  /// ⌘⇧X の入力の行き先で agent に任せると、⌘⇧X が閉じ、Home に起きた claude のタブへ移る。
  func testHandingOverFromTheTaskPaletteOpensClaudeInHomeWithTheRoleAndMovesThere() throws {
    let wc = try launch()
    XCTAssertTrue(wc.handleWindowKeyCommand(.showTaskPalette))
    let palette = try XCTUnwrap(wc.model.taskPalette)
    palette.query = "見積もりを山田さんに送る"

    palette.askWithQuery()

    XCTAssertEqual(wc.presentedOverlay, .none, "⌘⇧X は閉じる")
    let tab = try XCTUnwrap(try homeTabs(wc).first, "Home に claude のタブが起きる")
    XCTAssertEqual(wc.current.persistentId, homeId, "Home へ移る")
    XCTAssertEqual(wc.activeTab?.id, tab.id, "そのタブを選ぶ")
    let command = try XCTUnwrap(tab.surface.initialCommand)
    XCTAssertTrue(
      command.contains("--append-system-prompt") && command.contains("add_task")
        && !command.contains("set_automation"), "タスクを足す役目を添える: \(command)")
    XCTAssertTrue(command.hasSuffix(" -- '依頼: 見積もりを山田さんに送る'"), "頼みは最初の入力: \(command)")

    try wc.secretary.ask("二件目", from: .palette)
    XCTAssertEqual(try homeTabs(wc).count, 2, "頼みのたびに別の claude")
  }

  // MARK: - Home のボードから

  /// Home のボードの欄で頼むと、自動化の定義を書く役目の claude が Home に起きてそのタブへ移り、欄は空になる。
  func testTheBoardFieldOpensClaudeWithTheAutomationRoleAndClearsTheField() throws {
    let wc = try launch()
    let automation = wc.board.automation

    automation.requestText = "DM を候補に"
    automation.send()

    XCTAssertEqual(automation.requestText, "", "受けたら欄は空")
    XCTAssertNil(wc.board.refusal, "断らない")
    let tab = try XCTUnwrap(try homeTabs(wc).first, "Home に claude のタブが起きる")
    XCTAssertEqual(wc.activeTab?.id, tab.id, "そのタブへ移る")
    let command = try XCTUnwrap(tab.surface.initialCommand)
    let skill = (wc.secretaryPluginName.map { "\($0):" } ?? "") + "automation"
    XCTAssertTrue(
      command.contains("`\(skill)`") && !command.contains("add_task"),
      "自動化のスキルを名指しする役目を添える: \(command)")
    XCTAssertTrue(command.hasSuffix(" -- '依頼: DM を候補に'"), "欄の文は最初の入力: \(command)")
  }

  // MARK: - 受けない

  func testWithoutClaudeTheAskIsRefused() throws {
    let wc = try launch(stage: false)

    XCTAssertThrowsError(try wc.secretary.ask("頼み", from: .palette)) {
      XCTAssertEqual($0 as? Secretary.Refusal, .claudeMissing)
    }
    XCTAssertTrue(try homeTabs(wc).isEmpty)
  }

  /// 空の頼み（空白だけ）は claude の有無より先に空として断る——ボードの欄の空の ↵ は、claude が無くても黙る。
  func testAnEmptyAskIsRefusedAsEmptyEvenWithoutClaude() throws {
    let wc = try launch(stage: false)
    let automation = wc.board.automation

    automation.requestText = " \n "
    automation.send()

    XCTAssertNil(wc.board.refusal, "何も出さない")
    XCTAssertEqual(automation.requestText, " \n ", "欄はそのまま")
  }
}
