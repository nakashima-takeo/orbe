import OrbeSessionLog
import XCTest

@testable import Orbe

/// 自動化と候補の永続——再起動で同じ状態に戻ること、以前の版の intakes.json を一度だけ読み替えること、使えない原本を退避して
/// 空で始めること。
extension AutomationStoreTests {
  func testStateSurvivesARestart() throws {
    let store = try store(automations: 2)
    let a = Self.item("a")
    commit(store, 1, fetched: [a], proposing: [a])
    _ = try store.setPaused(1, true)
    var steps = Self.definition("受信 2")
    steps.steps = [
      AutomationStep(
        name: "絞り込み", method: .command(BackgroundCommand(script: "jq -c .", directory: "/tmp"))),
      AutomationStep(
        name: "判定",
        method: .agent(AutomationStepAgent(cli: "claude", model: nil, instruction: "判定して"))),
    ]
    _ = try store.replace(2, with: steps)

    let reloaded = AutomationStore()

    XCTAssertEqual(reloaded.automations, store.automations)
    XCTAssertEqual(reloaded.proposals, store.proposals)
    XCTAssertEqual(try reloaded.create(Self.definition(), now: t0).id, 3, "採番位置も戻る")
  }

  /// 以前の Orbe が書いた intakes.json を読み替え、同じ自動化・候補として持ち、その場で automations.json を書く。旧ファイル
  /// には触らない。この fixture はこの形で凍結しておく（型の変更に合わせて書き換えない）。
  ///
  /// 壊れると何が起きるか: 更新した利用者の自動化と候補が初回起動で消える。次の起動で移行がやり直され、新しい版で起きた
  /// ことが巻き戻る。旧版の Orbe に戻すと旧ファイルが読めない。
  func testLegacyFileIsMigratedOnceAndLeftUntouched() throws {
    let saved = """
      {"version":1,"nextIntakeId":3,"nextProposalId":2,"intakes":[{"id":2,"definition":{\
      "name":"Slack: 自分宛","fetch":{"agent":"claude","model":"haiku","tools":["mcp__slack__search"],\
      "request":"DM","coverage":"newArrivals"},"judge":{"agent":"claude","model":"sonnet","instruction":"自分がやること"},\
      "when":{"dailyAt":["09:00"]}},"paused":true,"createdAt":"2027-01-15T08:00:00.000Z",\
      "lastFetched":[{"id":"m1","link":"https://example.com/m1"}],"reviewAll":false,\
      "lastRunAt":"2027-01-15T09:00:00.000Z","runs":[{"startedAt":"2027-01-15T09:00:00.000Z",\
      "endedAt":"2027-01-15T09:01:00.000Z","trigger":"schedule","fetch":{"commandLine":"claude -p",\
      "ending":"exited 0","items":1,"rejected":{"count":0,"reasons":[]}},"newItems":1,\
      "judge":{"commandLine":"claude -p","ending":"exited 0","proposed":1,"resolved":0,\
      "rejected":{"count":1,"reasons":["line 2: not JSON"]}},"withdrawn":0}]}],\
      "proposals":[{"id":1,"intakeId":2,"item":{"id":"m1","link":"https://example.com/m1",\
      "body":"返信ください","time":"2027-01-15T08:30:00.000Z"},"title":"返信する","due":"2027-01-16",\
      "proposedAt":"2027-01-15T09:01:00.000Z","state":"accepted","taskId":7}]}
      """
    let legacy = try automationsFile().deletingLastPathComponent()
      .appendingPathComponent("intakes.json")
    try Data(saved.utf8).write(to: legacy)

    let store = AutomationStore()

    let automation = try XCTUnwrap(store.automation(2), "退避せずに読む")
    XCTAssertEqual(
      automation.definition,
      AutomationDefinition(
        name: "Slack: 自分宛", trigger: .daily([.init(hour: 9, minute: 0)]),
        source: AutomationSource(
          method: .agent(
            AutomationSourceAgent(
              cli: "claude", model: "haiku", tools: ["mcp__slack__search"], request: "DM")),
          coverage: .newArrivals),
        steps: [
          AutomationStep(
            name: "判定",
            method: .agent(
              AutomationStepAgent(cli: "claude", model: "sonnet", instruction: "自分がやること")))
        ],
        sink: .taskCandidates))
    XCTAssertTrue(automation.paused)
    XCTAssertEqual(
      automation.lastFetched, [AutomationSeen(id: "m1", link: "https://example.com/m1")])
    XCTAssertEqual(automation.lastRunAt, SessionEvent.parseISO8601("2027-01-15T09:00:00.000Z"))
    let run = try XCTUnwrap(automation.runs.first)
    XCTAssertEqual(run.source?.count, 1)
    XCTAssertEqual(run.fresh, 1)
    XCTAssertEqual(run.steps.map(\.name), ["判定"])
    XCTAssertEqual(Self.candidates(run)?.proposed, 1)
    XCTAssertEqual(Self.candidates(run)?.rejected.reasons, ["line 2: not JSON"])
    XCTAssertEqual(automation.lastSucceededAt, run.startedAt, "失敗でない最新の回の開始時刻")
    XCTAssertEqual(store.proposals.first?.automationId, 2)
    XCTAssertEqual(store.proposals.first?.state, .accepted(taskId: 7))
    XCTAssertEqual(store.proposals.first?.due?.text, "2027-01-16")

    XCTAssertEqual(
      AutomationPersistence.load()?.automations, store.automations,
      "読み替えた時点で automations.json を書く")
    XCTAssertEqual(try Data(contentsOf: legacy), Data(saved.utf8), "旧ファイルは書き換えない")
    XCTAssertEqual(try store.create(Self.definition(), now: t0).id, 3, "採番位置も読む")
  }

  /// 使えない automations.json は退避し、その場で空の automations.json を書く——古い intakes.json へ巻き戻らない。
  func testBrokenFileIsQuarantinedAndStartsEmpty() throws {
    let url = try automationsFile()
    try Data("{\"version\":1}".utf8).write(to: url)
    try Data(
      #"{"version":1,"nextIntakeId":5,"nextProposalId":1,"intakes":[],"proposals":[]}"#.utf8
    ).write(to: url.deletingLastPathComponent().appendingPathComponent("intakes.json"))

    XCTAssertTrue(AutomationStore().automations.isEmpty)
    XCTAssertEqual(AutomationPersistence.load(), .empty, "空の automations.json が在る")
  }
}
