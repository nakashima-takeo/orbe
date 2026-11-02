import XCTest

@testable import Orbe

/// カードの「workspace」の欄。コマンドのノードに走る workspace があるときだけ「作業ディレクトリ」の直前に出て、名前は描くときの
/// 今の workspace で解く。自動化から継いだときは継いだ印、消えた workspace は消えた印を言う。
///
/// 壊れると何が起きるか: 相対の作業ディレクトリがどこからの相対か画面で分からない。自動化から継いだのか、ノードに書いたのかが
/// 分からず、自動化の workspace を替えたときに動く場所を読み違える。消えた workspace のノードが、なぜ始まらないか分からない。
/// agent や workspace の無いコマンドに空の欄が出る。
@MainActor
final class BoardAutomationWorkspaceCardTests: OrbeTestCase {
  private func card(_ automation: Int, _ key: String, _ language: Language = .ja) throws
    -> [(label: L10nKey, value: String)]
  {
    let store = DesignSceneFixtures.automationStore(DesignSceneFixtures.boardWorkspaceSamples())
    let text = AutomationText(
      l10n: LocalizationStore(language: language),
      today: .today(
        DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
      timeZone: DesignSceneFixtures.taskCalendar.timeZone)
    let value = try XCTUnwrap(
      BoardAutomationNodeValue(
        store.automations[automation], key: key, text: text, running: false, next: nil, open: 0,
        workspaces: DesignSceneFixtures.boardWorkspaces))
    return value.facts.map { ($0.label, $0.value.map(\.text).joined()) }
  }

  private func place(_ facts: [(label: L10nKey, value: String)]) -> [String] {
    facts.filter { [.boardNodeWorkspace, .boardNodeDirectory].contains($0.label) }.map(\.value)
  }

  func testTheWorkspaceFactSaysWhereTheCommandRunsRightBeforeTheDirectory() throws {
    XCTAssertEqual(place(try card(0, "prs")), ["orbe（自動化の設定）", "."], "継いだ")
    XCTAssertEqual(place(try card(0, "sync")), ["dotfiles", "bin"], "ノードに書いた")
    XCTAssertEqual(place(try card(0, "archive")), ["削除済み", "tools"])
    XCTAssertEqual(place(try card(1, "clean")), ["削除済み（自動化の設定）", "."])
    XCTAssertEqual(place(try card(0, "prs", .en)), ["orbe (automation setting)", "."])
    XCTAssertEqual(
      try card(0, "prs").map(\.label).suffix(3),
      [.boardNodeWorkspace, .boardNodeDirectory, .boardNodeNext])
  }

  func testNodesThatRunInNoWorkspaceHaveNoWorkspaceFact() throws {
    let store = DesignSceneFixtures.automationStore(DesignSceneFixtures.boardMapSamples())
    let text = AutomationText(
      l10n: LocalizationStore(language: .ja),
      today: .today(
        DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
      timeZone: DesignSceneFixtures.taskCalendar.timeZone)
    for automation in store.automations {
      for node in automation.graph.nodes {
        let value = try XCTUnwrap(
          BoardAutomationNodeValue(
            automation, nodeId: node.id, text: text, running: false, next: nil, open: 0,
            workspaces: DesignSceneFixtures.boardWorkspaces))
        XCTAssertFalse(value.facts.contains { $0.label == .boardNodeWorkspace }, node.key)
      }
    }
  }
}
