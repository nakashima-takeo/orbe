import XCTest

@testable import Orbe

/// 書く前の定義の試走の入口——`set_automation` と同じ読み・席・ストアの確かめを通り、試す対象を組む。
///
/// 壊れると何が起きるか: 試走では受かった定義が `set_automation` で断られる（またはその逆）、断りの文が違い AI が直す場所を
/// 読み違える。版の無い直す試走や定義の無い版が、黙って保存した定義の試走になる。定義を読めない自動化を、直す前に試せない。
extension WindowControllerAutomationControlTests {
  private func json(_ definition: AutomationDefinition) -> [String: Any] {
    AutomationWire.object(definition) as? [String: Any] ?? [:]
  }

  private func refusal(_ result: Result<Any, ControlError>) -> (code: Int, message: String)? {
    if case .failure(let error) = result { return (error.code, error.message) }
    return nil
  }

  /// 試走に渡す自動化・版・定義。
  private struct Attempt {
    let automationId: Int?
    let version: Int?
    let definition: [String: Any]?
  }

  /// 書く前の定義の誤り（形・定義の中の参照・workspace の席・新しい定義のノードの id・この自動化のノードでない id・版の欠け・
  /// 版の食い違い・知らない自動化）は、`set_automation` と同じコードと文で断られ、試走は始まらない。
  func testAnUnsavedDefinitionIsRefusedExactlyAsSetAutomationRefusesIt() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition())
    let saved = try XCTUnwrap(wc.automationStore.automation(id))
    var unknownInput = Self.definition()
    unknownInput.nodes[1].from = [AutomationDefinition.Input(nodeKey: "nope")]
    var seat = Self.definition()
    seat.nodes[0].action.method = .command(
      AutomationNodeCommand(script: "true", workspace: UUID(), directory: "."))
    var foreignId = saved.definition
    foreignId.nodes[0].id = AutomationNodeID(999)
    for attempt in [
      Attempt(automationId: nil, version: nil, definition: ["name": "x"]),
      Attempt(automationId: nil, version: nil, definition: json(unknownInput)),
      Attempt(automationId: nil, version: nil, definition: json(seat)),
      Attempt(automationId: nil, version: nil, definition: json(saved.definition)),
      Attempt(automationId: id, version: 1, definition: json(foreignId)),
      Attempt(automationId: id, version: nil, definition: json(saved.definition)),
      Attempt(automationId: id, version: 7, definition: json(saved.definition)),
      Attempt(automationId: 99, version: 1, definition: json(Self.definition())),
    ] {
      let definition = attempt.definition ?? [:]
      let label =
        "\(attempt.automationId as Any) \(attempt.version as Any) \(definition["name"] ?? "")"
      let tried = try XCTUnwrap(
        refusal(
          wc.controlTryAutomation(
            automationId: attempt.automationId, version: attempt.version,
            definition: definition, .init())),
        label)
      let written = try XCTUnwrap(
        refusal(
          wc.controlSetAutomation(
            automationId: attempt.automationId, version: attempt.version, definition)),
        label)
      XCTAssertEqual(tried.code, written.code, label)
      XCTAssertEqual(tried.message, written.message, label)
    }
    XCTAssertEqual(wc.automationStore.automations, [saved])
    XCTAssertThrowsError(try wc.automationTrials.trial(1), "試走は始まらない")
  }

  /// 版は直す定義（自動化と定義）にだけ添え、自動化も定義も無い試走は組めない。どれも -32602。
  func testAVersionGoesOnlyWithARewriteAndATrialNeedsSomethingToTry() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition())
    for attempt in [
      Attempt(automationId: id, version: 1, definition: nil),
      Attempt(automationId: nil, version: 1, definition: json(Self.definition())),
      Attempt(automationId: nil, version: nil, definition: nil),
    ] {
      let refused = refusal(
        wc.controlTryAutomation(
          automationId: attempt.automationId, version: attempt.version,
          definition: attempt.definition, .init()))
      XCTAssertEqual(
        refused?.code, -32602, "\(attempt.automationId as Any) \(attempt.version as Any)")
    }
  }

  /// 定義を読めない自動化も、直す定義を渡せば直したものとして試せる（本番は読めないまま）。定義を渡さない試走は読めない理由で断る。
  func testAnUnreadableAutomationCanBeTriedWithItsRewrite() throws {
    try {
      let store = AutomationStore()
      let id = try store.create(Self.definition(), now: Date()).id
      try store.read {
        try $0.db.run(
          """
          UPDATE action_defs SET action = '{"model": "sonnet", "instruction": 1}'
          WHERE id = (SELECT def_id FROM nodes WHERE automation_id = ? AND key = 'judge')
          """, [.integer(Int64(id))])
      }
    }()
    let wc = try launch()
    XCTAssertEqual(
      refusal(
        wc.controlTryAutomation(automationId: 1, version: nil, definition: nil, .init()))?.code,
      -32000)
    let nodes = try XCTUnwrap((try listed(wc)[1]?["definition"] as? [String: Any])?["nodes"])
    var fixed = Self.definition()
    for (index, node) in ((nodes as? [[String: Any]]) ?? []).enumerated() {
      fixed.nodes[index].id = (node["id"] as? Int).map(AutomationNodeID.init)
    }
    let row = #"{"id":"a","link":"https://example.com/a","body":"a","time":"2026-10-10T09:00:00Z"}"#

    let started = try success(
      wc.controlTryAutomation(
        automationId: 1, version: 1, definition: json(fixed),
        .init(from: ["fetch"], to: ["fetch"], rows: [row])))
    let trialId = try XCTUnwrap((started["trial"] as? [String: Any])?["trialId"] as? Int)
    var reply: Result<Any, ControlError>?
    wc.controlAutomationTrial(trialId: trialId, wait: true, timeoutMs: 5000) { reply = $0 }
    let deadline = Date().addingTimeInterval(5)
    while reply == nil && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let trial = try XCTUnwrap(try success(try XCTUnwrap(reply))["trial"] as? [String: Any])
    XCTAssertNil(trial["failure"])
    XCTAssertEqual((trial["nodes"] as? [[String: Any]])?.map { $0["state"] as? String }, ["given"])
    XCTAssertNotNil(try listed(wc)[1]?["definitionError"], "本番は読めないまま")
  }
}
