import XCTest

@testable import Orbe

/// ボードの workspace の言い方。カードの「workspace」の欄は、コマンドのノードに走る workspace があるときだけ「作業ディレクトリ」の
/// 直前に名前を出し、詳細の見出しは、自動化に workspace の設定があるときだけ「workspace：名前」の行を出す。名前は描くときの今の
/// workspace で解き、消えた workspace は「削除済み」と言う。
///
/// 壊れると何が起きるか: 相対の作業ディレクトリがどこからの相対か画面で分からない。自動化の workspace がどこか画面で分からない。
/// 消えた workspace のノードが、なぜ始まらないか分からない。agent や workspace の無いコマンド、workspace の無い自動化に空の欄が
/// 出る。
@MainActor
final class BoardAutomationWorkspaceTests: OrbeTestCase {
  private let text = AutomationText(
    l10n: LocalizationStore(language: .ja),
    today: .today(
      DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
    timeZone: DesignSceneFixtures.taskCalendar.timeZone)

  private func card(_ automation: Int, _ key: String) throws -> [(label: L10nKey, value: String)] {
    let store = DesignSceneFixtures.automationStore(DesignSceneFixtures.boardWorkspaceSamples())
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
    XCTAssertEqual(place(try card(0, "prs")), ["orbe", "."], "継いだ")
    XCTAssertEqual(place(try card(0, "sync")), ["dotfiles", "bin"], "ノードに書いた")
    XCTAssertEqual(place(try card(0, "archive")), ["削除済み", "tools"])
    XCTAssertEqual(place(try card(1, "clean")), ["削除済み", "."])
    XCTAssertEqual(
      try card(0, "prs").map(\.label).suffix(3),
      [.boardNodeWorkspace, .boardNodeDirectory, .boardNodeNext])
  }

  func testNodesThatRunInNoWorkspaceHaveNoWorkspaceFact() throws {
    let store = DesignSceneFixtures.automationStore(DesignSceneFixtures.boardMapSamples())
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

  func testTheHeadingSaysTheAutomationWorkspaceOnlyWhenItHasOne() {
    func heading(_ samples: [AutomationSample]) -> [String?] {
      DesignSceneFixtures.automationStore(samples).automations.map {
        BoardAutomationDetailValue(
          $0, text: text, running: { _ in false }, open: 0, next: nil,
          workspaces: DesignSceneFixtures.boardWorkspaces
        ).workspace
      }
    }

    XCTAssertEqual(
      heading(DesignSceneFixtures.boardWorkspaceSamples()), ["workspace：orbe", "workspace：削除済み"])
    XCTAssertEqual(Set(heading(DesignSceneFixtures.boardMapSamples())), [nil])
  }
}
