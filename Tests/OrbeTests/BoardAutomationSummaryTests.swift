import XCTest

@testable import Orbe

/// ボードの読み替え——一覧の行（状態と、それと混ぜない前回の成否と時刻）と、地図の溝の線の割り当て。
///
/// 壊れると何が起きるか: 失敗した部品があるのに一覧の印が成功に見え、壊れた部品に気づけない。流している間や止めている間に
/// 前回の結果が見えなくなる。地図の線が入力と違う行へつながり、
/// どの部品の出力がどこへ行くかを読み違える。
@MainActor
final class BoardAutomationSummaryTests: OrbeTestCase {
  private let text = AutomationText(
    l10n: LocalizationStore(language: .ja),
    today: .today(
      DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
    timeZone: DesignSceneFixtures.taskCalendar.timeZone)

  private func automations() -> [Automation] {
    DesignSceneFixtures.automationStore(DesignSceneFixtures.boardMapSamples()).automations
  }

  /// 失敗した部品があれば失敗の印。時刻はどの部品かを問わず最後に動いた時刻で、昨日なら「昨日」。
  func testListRowSaysTheLastMarkAndTime() throws {
    let all = automations()
    let charge = BoardAutomationSummary(all[0], text: text, next: nil)
    XCTAssertEqual(charge.mark, .failure)
    XCTAssertEqual(charge.last, "前回 14:56")

    let script = BoardAutomationSummary(all[1], text: text, next: nil)
    XCTAssertEqual(script.mark, .success)
    XCTAssertEqual(script.last, "前回 昨日 23:00")

    let wide = BoardAutomationSummary(all[2], text: text, next: nil)
    XCTAssertNil(wide.mark)
    XCTAssertEqual(wide.last, "まだ動いていない")
  }

  /// 名前の右の状態（実行中・停止中）と前回の印は混ぜない。失敗した部品のある自動化を流している間も印は失敗のまま、止めて
  /// いる自動化の印は前回の成否のまま。
  func testListRowKeepsTheStateApartFromTheLastResult() throws {
    let model = BoardAutomationModel(
      runner: DesignSceneFixtures.automationRunner(DesignSceneFixtures.boardMapSamples()))
    let all = model.store.automations
    let (charge, weekend) = (all[0].id, all[3].id)
    try model.runner.flow(charge, to: .ends)
    let now = model.runner.now()
    let text = model.text(LocalizationStore(language: .ja), now: now)
    let states = Dictionary(
      uniqueKeysWithValues: model.standings(at: now).map { ($0.id, $0.state) })

    XCTAssertEqual(states[charge], .running)
    XCTAssertEqual(model.summary(charge, text: text, now: now)?.mark, .failure, "流している間も前回の印")
    XCTAssertEqual(states[weekend], .paused)
    XCTAssertEqual(model.summary(weekend, text: text, now: now)?.mark, .success, "止めていても前回の印")
  }

  /// 見本の 12 部品の線: 行を上から見て、最後の受け手を迎える入力の線のうち最も左に点を置き、無ければ空いている最も左。
  func testMapLanesFollowTheInputs() throws {
    let detail = BoardAutomationDetailValue(
      automations()[0], text: text, running: { _ in false }, open: 0, next: nil)

    XCTAssertEqual(detail.rows.map(\.lanes.node), [0, 1, 2, 3, 4, 5, 3, 4, 5, 2, 0, 4, 0, 2])
    XCTAssertEqual(detail.laneCount, 6)
    let develop = detail.rows[10].lanes
    XCTAssertEqual(develop.bends, [1, 3], "CI と自分の担当だけの線が点へ曲がり込む")
    XCTAssertEqual(develop.through, [2, 4, 5])
  }

  /// カードの「ツール」: MCP は `__` までをサーバー名とし、claude.ai のコネクタ・プラグインの出どころの頭は落とす。Bash 規則は
  /// 末尾の `:*` の手前までがコマンド。同じ表示は最初の 1 つだけ。
  func testCardToolsNameTheServerOrCommandOnce() throws {
    var samples = DesignSceneFixtures.boardMapSamples()
    let index = try XCTUnwrap(samples[0].definition.parts.firstIndex { $0.key == "backlog" })
    samples[0].definition.parts[index].method = .agent(
      AutomationPartAgent(
        cli: "claude", model: nil,
        tools: [
          "mcp__claude_ai_Gmail__search_threads", "mcp__plugin_core_backlog__get_issues",
          "mcp__claude_ai_Gmail__get_thread", "Bash(npm run test:unit:*)",
          "Bash(npm run test:unit:*)",
        ],
        instruction: "取る。"))
    let automation = DesignSceneFixtures.automationStore(samples).automations[0]
    let card = try XCTUnwrap(
      BoardAutomationPartValue(
        automation, part: "backlog", text: text, running: false, next: nil, open: 0))

    XCTAssertEqual(
      card.facts.first { $0.label == .boardPartTools }?.value.map(\.text),
      ["Gmail（MCP）・Backlog（MCP）・npm run test:unit コマンド"])
  }
}
