import XCTest

@testable import Orbe

/// 部品のグラフ——通る組み合わせ・役割・地図の並び。
///
/// 壊れると何が起きるか: Issue の形の自動化が登録できない。ツールを持つ agent が処理や判定と導かれ、外の文面がツールを持つ
/// agent の依頼文に入る。地図で入力の部品が下に描かれ線が逆流する。
final class AutomationGraphTests: OrbeTestCase {
  static let tool = "mcp__slack__post"
  static let everyTenMinutes = AutomationNode.Trigger.scheduled(.every(600))

  /// 入力の無いコマンドの、取得の部品。
  static func fetch(
    _ key: String, _ coverage: AutomationCoverage = .currentSet,
    trigger: AutomationNode.Trigger = everyTenMinutes
  ) -> AutomationDefinition.Node {
    DesignSceneFixtures.commandNode(
      key, key, trigger, script: "fetch \(key)", coverage: coverage)
  }

  static func agent(
    _ key: String, from inputs: [String] = [], tools: [String] = [],
    deliver: AutomationActionDef.Destination = .report, coverage: AutomationCoverage? = nil,
    trigger: AutomationNode.Trigger = .manual
  ) -> AutomationDefinition.Node {
    DesignSceneFixtures.agentNode(
      key, key, trigger, from: inputs, tools: tools, instruction: "\(key) して", coverage: coverage,
      deliver: deliver)
  }

  static func command(
    _ key: String, from inputs: [String] = [],
    deliver: AutomationActionDef.Destination = .sideEffect,
    trigger: AutomationNode.Trigger = .manual
  ) -> AutomationDefinition.Node {
    DesignSceneFixtures.commandNode(
      key, key, trigger, from: inputs, script: "run \(key)", deliver: deliver)
  }

  /// Issue の動機の例と、今の 4 種の写し方の表の各行は通る。
  func testTheShapesFromTheIssuePass() throws {
    let nineEveryDay = AutomationNode.Trigger.scheduled(.cron(try BackgroundCron("0 9 * * *")))
    let sources = ["gh-prs", "backlog", "slack_dm"]
    let shapes: [(String, [AutomationDefinition.Node])] = [
      (
        "出どころごとの予定 → 1 日 1 回の判定、同じ取得結果 → 届いたら要約",
        [
          Self.fetch("gh-prs"),
          Self.fetch("backlog", .newArrivals, trigger: .scheduled(.every(1800))),
          Self.fetch("slack_dm", .newArrivals),
          Self.agent("judge", from: sources, deliver: .taskCandidates, trigger: nineEveryDay),
          Self.agent("summary", from: sources, trigger: .arrival),
        ]
      ),
      (
        "取得 → 処理 → 判定",
        [
          Self.fetch("f"), Self.agent("p", from: ["f"], deliver: .nextNode, trigger: .arrival),
          Self.agent("j", from: ["p"], deliver: .taskCandidates, trigger: .arrival),
        ]
      ),
      ("入力の無いコマンド", [Self.command("c", trigger: Self.everyTenMinutes)]),
      (
        "取得 → 処理 → コマンド",
        [
          Self.fetch("f"), Self.agent("p", from: ["f"], deliver: .nextNode, trigger: .arrival),
          Self.command("c", from: ["p"], trigger: .arrival),
        ]
      ),
      (
        "取得 → 毎回すべてを取る報告",
        [Self.fetch("f"), Self.taking(.all, Self.agent("r", from: ["f"], trigger: .arrival))]
      ),
      (
        "取得 → 今の集合を写す処理 → 判定",
        [
          Self.fetch("f"),
          Self.taking(
            .all,
            Self.agent(
              "p", from: ["f"], deliver: .nextNode, coverage: .currentSet, trigger: .arrival)),
          Self.agent("r", from: ["p"], trigger: .arrival),
        ]
      ),
      ("ツールを持つ agent", [Self.agent("w", tools: [Self.tool], trigger: Self.everyTenMinutes)]),
      (
        "毎回すべてを合図にだけ使うツールを持つ agent の項目を判定する",
        [
          Self.fetch("f"),
          Self.taking(
            .all,
            Self.agent(
              "gate", from: ["f"], tools: [Self.tool], deliver: .nextNode, coverage: .newArrivals)),
          Self.agent("j", from: ["gate"], deliver: .taskCandidates),
        ]
      ),
    ]
    for (label, definitionNodes) in shapes {
      XCTAssertNoThrow(try AutomationGraph.numbered(definitionNodes), label)
    }
  }

  /// 部品の入力をすべて `take` で取る形にする。
  static func taking(_ take: AutomationTake, _ definitionNode: AutomationDefinition.Node)
    -> AutomationDefinition.Node
  {
    var definitionNode = definitionNode
    definitionNode.from = definitionNode.from.map {
      AutomationDefinition.Input(part: $0.part, take: take)
    }
    return definitionNode
  }

  /// 役割は部品自身の欄（入力・ツール・行き先）から Issue の役割の表どおりに導かれる。入力を合図にだけ使うツールを持つ agent は
  /// 行を見ないので取得。
  func testRolesFollowEachNodesOwnFields() throws {
    let graph = try AutomationGraph.numbered([
      Self.fetch("fetch"),
      Self.agent(
        "gate", from: ["fetch"], tools: [Self.tool], deliver: .nextNode, coverage: .newArrivals),
      Self.agent("process", from: ["fetch"], deliver: .nextNode),
      Self.command("processCommand", from: ["fetch"], deliver: .nextNode),
      Self.agent("judge", from: ["gate", "process", "processCommand"], deliver: .taskCandidates),
      Self.agent("report", from: ["fetch"]),
      Self.agent("reportAlone"),
      Self.agent("work", from: ["fetch"], tools: [Self.tool]),
      Self.command("sideEffect", from: ["fetch"]),
    ])

    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.key, $0.role) }),
      [
        "fetch": .fetch, "gate": .fetch, "process": .process,
        "processCommand": .process, "judge": .judge, "report": .report, "reportAlone": .report,
        "work": .work, "sideEffect": .sideEffect,
      ])
  }

  /// 地図の並びは入力の深さ順（深さは最も長い道で数える）で、同じ深さは定義の順。入力の部品がいつも先に並ぶ。
  func testNodesLineUpByInputDepthThenDefinitionOrder() throws {
    let graph = try AutomationGraph.numbered([
      Self.agent("r", from: ["a", "p"]),
      Self.agent("p", from: ["b"], deliver: .nextNode),
      Self.fetch("b"),
      Self.fetch("a"),
    ])

    XCTAssertEqual(graph.byDepth.map(\.key), ["b", "a", "p", "r"])
  }

  /// 処理の出力の性質は書かなければ出来事の流れで、書けば書いたとおり。行を出さない部品は持たない。
  func testAProcessCoverageDefaultsToNewArrivals() throws {
    let graph = try AutomationGraph.numbered([
      Self.fetch("f"),
      Self.agent("p", from: ["f"], deliver: .nextNode),
      Self.taking(.all, Self.agent("q", from: ["f"], deliver: .nextNode, coverage: .currentSet)),
      Self.agent("r", from: ["p", "q"]),
    ])

    XCTAssertEqual(graph.nodes.map(\.coverage), [.currentSet, .newArrivals, .currentSet, nil])
  }

  /// 外の形へ組み直すと、取り方も古さの上限も省いた入力は鍵だけに、ほかは書いたとおりに戻る。
  func testTheNodesRoundTripTheirInputs() throws {
    var receiver = Self.agent("r", from: ["f", "g"])
    receiver.from[1] = AutomationDefinition.Input(part: "g", take: .all, maxAgeHours: 24)
    let definitionNodes = [Self.fetch("f"), Self.fetch("g"), receiver]

    let graph = try AutomationGraph.numbered(definitionNodes)

    XCTAssertEqual(graph.definitionNodes.map(\.from), definitionNodes.map(\.from))
  }
}

extension AutomationGraph {
  /// 検証して、部品と定義に 1 から順の ID を振る（テストの見本）。
  static func numbered(_ definitionNodes: [AutomationDefinition.Node]) throws(AutomationError)
    -> AutomationGraph
  {
    let checked = try check(definitionNodes)
    return AutomationGraph(
      checked,
      entities: checked.enumerated().map { index, item in
        AutomationNode(
          id: AutomationNodeID(index + 1), key: item.definitionNode.key,
          name: item.definitionNode.name,
          trigger: item.definitionNode.trigger, maxItems: item.definitionNode.maxItems,
          defId: AutomationNodeDefID(index + 1))
      })
  }
}
