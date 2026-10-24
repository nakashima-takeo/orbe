import XCTest

@testable import Orbe

/// ボードの読み替え——一覧の行（状態と、それと混ぜない前回の成否と時刻）と、地図の溝の線の割り当て、カードの実行履歴の文。
///
/// 壊れると何が起きるか: 失敗したノードがあるのに一覧の印が成功に見え、壊れたノードに気づけない。流している間や止めている間に
/// 前回の結果が見えなくなる。地図の線が入力と違う行へつながり、
/// どのノードの出力がどこへ行くかを読み違える。英語の実行履歴と知らせが「judged 1 items」と言う。新着なしの回が他の回を
/// 押し出す、または畳んではいけない回（新着のある回・形式エラーを修正した回）が畳まれて見えなくなる。
@MainActor
final class BoardAutomationSummaryTests: OrbeTestCase {
  private let text = AutomationText(
    l10n: LocalizationStore(language: .ja),
    today: .today(
      DesignSceneFixtures.taskToday, timeZone: DesignSceneFixtures.taskCalendar.timeZone),
    timeZone: DesignSceneFixtures.taskCalendar.timeZone)

  /// カードの実行履歴の各行の文（畳んだ行は期間の文）。
  private func said(_ lines: [BoardRunLine]) -> [String] {
    lines.map {
      switch $0 {
      case .run(let entry): entry.result
      case .fold(let span): span
      }
    }
  }

  private func automations() -> [Automation] {
    DesignSceneFixtures.automationStore(DesignSceneFixtures.boardMapSamples()).automations
  }

  /// 失敗したノードがあれば失敗の印。時刻はどのノードかを問わず最後に動いた時刻で、昨日なら「昨日」。
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
    XCTAssertEqual(wide.last, "未実行")
  }

  /// 名前の右の状態（実行中・停止中）と前回の印は混ぜない。失敗したノードのある自動化を流している間も印は失敗のまま、止めて
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
      uniqueKeysWithValues: model.standings.map { ($0.id, $0.state) })

    XCTAssertEqual(states[charge], .running)
    XCTAssertEqual(model.summary(charge, text: text, now: now)?.mark, .failure, "流している間も前回の印")
    XCTAssertEqual(states[weekend], .paused)
    XCTAssertEqual(model.summary(weekend, text: text, now: now)?.mark, .success, "止めていても前回の印")
  }

  /// 見本の 12 ノードの線: 行を上から見て、最後の受け手を迎える入力の線のうち最も左に点を置き、無ければ空いている最も左。
  func testMapLanesFollowTheInputs() throws {
    let detail = BoardAutomationDetailValue(
      automations()[0], text: text, running: { _ in false }, open: 0, next: nil)

    XCTAssertEqual(detail.rows.map(\.lanes.lane), [0, 1, 2, 3, 4, 5, 3, 4, 5, 2, 0, 4, 0, 2])
    XCTAssertEqual(detail.laneCount, 6)
    let develop = detail.rows[10].lanes
    XCTAssertEqual(develop.bends, [1, 3], "CI と自分の担当だけの線が点へ曲がり込む")
    XCTAssertEqual(develop.through, [2, 4, 5])
  }

  /// カードの「ツール」: MCP は `__` までをサーバー名とし、claude.ai のコネクタ・プラグインの出どころの頭は落とす。Bash 規則は
  /// 末尾の `:*` の手前までがコマンド。同じ表示は最初の 1 つだけ。
  func testCardToolsNameTheServerOrCommandOnce() throws {
    var samples = DesignSceneFixtures.boardMapSamples()
    let index = try XCTUnwrap(samples[0].definition.nodes.firstIndex { $0.key == "backlog" })
    samples[0].definition.nodes[index].action.method = .agent(
      AutomationNodeAgent(
        cli: "claude", model: nil,
        tools: [
          "mcp__claude_ai_Gmail__search_threads", "mcp__plugin_core_backlog__get_issues",
          "mcp__claude_ai_Gmail__get_thread", "Bash(npm run test:unit:*)",
          "Bash(npm run test:unit:*)",
        ],
        instruction: "取る。"))
    let automation = DesignSceneFixtures.automationStore(samples).automations[0]
    let card = try XCTUnwrap(
      BoardAutomationNodeValue(
        automation, key: "backlog", text: text, running: false, next: nil, open: 0))

    XCTAssertEqual(
      card.facts.first { $0.label == .boardNodeTools }?.value.map(\.text),
      ["Gmail（MCP）・Backlog（MCP）・npm run test:unit コマンド"])
  }

  /// 一覧の失敗の印は、最後の回が失敗したノードだけで決まる。失敗の後に成功したノードは数えない。
  func testListMarkCountsOnlyNodesWhoseLatestRunFailed() throws {
    let at = { (hour: Int) in DesignSceneFixtures.automationAt(hour) }
    func fetch(_ key: String) -> AutomationDefinition.Node {
      DesignSceneFixtures.commandNode(
        key, key, .scheduled(.every(3600)), script: key, coverage: .newArrivals)
    }
    func mark(_ failing: [String]) throws -> BoardRunMark? {
      let failed = DesignSceneFixtures.failed("boom")
      let sample = AutomationSample(
        definition: AutomationDefinition(
          name: "失敗", notify: nil,
          nodes: [
            fetch("broken"), fetch("recovered"),
            DesignSceneFixtures.agentNode(
              "judge", "判定", .manual, from: ["broken", "recovered"], instruction: "i",
              deliver: .taskCandidates),
          ]),
        createdAt: DesignSceneFixtures.automationAt(9, daysAgo: 3),
        passes: failing.map { AutomationSamplePass(nodeKey: $0, at: at(9), outcome: failed) } + [
          AutomationSamplePass(nodeKey: "recovered", at: at(8), outcome: failed),
          AutomationSamplePass(
            nodeKey: "recovered", at: at(10),
            outcome: DesignSceneFixtures.fetched(
              DesignSceneFixtures.sampleItems("recovered", 1, at: at(10)))),
        ])
      let automation = try XCTUnwrap(
        DesignSceneFixtures.automationStore([sample]).automations.first)
      return BoardAutomationSummary(automation, text: text, next: nil).mark
    }

    XCTAssertEqual(try mark(["broken"]), .failure)
    XCTAssertEqual(try mark([]), .success, "失敗の後に成功したノードは数えない")
  }

  /// 処理の回の「N 件中 M 件を出力」の M は出した件数——今の集合の処理が毎回全件を写す回も、新しく届く行の数で「0 件を出力」と
  /// 言わない。
  func testAProcessRunSaysHowManyRowsItGave() throws {
    let run = AutomationNodeRun(
      startedAt: DesignSceneFixtures.automationAt(9), endedAt: DesignSceneFixtures.automationAt(9),
      trigger: .arrival, taken: 10,
      execution: DesignSceneFixtures.execution(10), result: .process(fresh: 0, duplicates: 0))
    let node = try XCTUnwrap(automations().first?.graph.nodes.first)

    XCTAssertEqual(BoardAutomationSummary.amount(run, text: text)?.text, "10 件を出力")
    XCTAssertEqual(BoardAutomationSummary.amount(run, text: text)?.shade, .plain)
    XCTAssertEqual(
      BoardAutomationSummary.result(run, node: node, text: text).text, "10 件中 10 件を出力")
  }

  /// 英語の判定の回は、判定した件数が 1 なら単数で言う。
  func testJudgedRunSaysItemsInTheSingularWhenOneInEnglish() throws {
    let at = { (hour: Int) in DesignSceneFixtures.automationAt(hour) }
    let sample = AutomationSample(
      definition: DesignSceneFixtures.candidatesDefinition(
        "判定",
        fetch: DesignSceneFixtures.commandNode(
          "fetch", "取得", .scheduled(.every(3600)), script: "f", coverage: .newArrivals)),
      createdAt: at(8),
      passes: DesignSceneFixtures.round("one", at: at(9), items: 1, fresh: 1, proposed: 1)
        + DesignSceneFixtures.round("three", at: at(10), items: 3, fresh: 3, proposed: 2))
    let automation = try XCTUnwrap(DesignSceneFixtures.automationStore([sample]).automations.first)
    let english = AutomationText(
      l10n: LocalizationStore(language: .en), today: text.today, timeZone: text.timeZone)

    let card = try XCTUnwrap(
      BoardAutomationNodeValue(
        automation, key: "judge", text: english, running: false, next: nil, open: 0))

    XCTAssertEqual(said(card.runs), ["judged 3 items, 2 proposed", "judged 1 item, 1 proposed"])
  }

  /// カードの実行履歴は、添え書きの無い新着なしが 3 回以上続く区間だけを期間の 1 行に畳む。1 回だけの新着なしと、形式エラーを
  /// 修正して通った回（末尾に添え書き）は 1 行ずつ残す。
  func testCardHistoryFoldsOnlyLongStretchesOfNothingNew() throws {
    let automation = automations()[0]
    func card(_ nodeKey: String) throws -> [String] {
      said(
        try XCTUnwrap(
          BoardAutomationNodeValue(
            automation, key: nodeKey, text: text, running: false, next: nil, open: 0)
        ).runs)
    }

    XCTAssertEqual(
      try card("slack"), ["13:10〜14:55 は新着なし", "新着 4 件", "新着 5 件", "新着 6 件"])
    XCTAssertEqual(try card("mail"), ["新着 2 件（形式エラーを agent が修正済み）", "新着なし", "新着 1 件"])
  }
}
