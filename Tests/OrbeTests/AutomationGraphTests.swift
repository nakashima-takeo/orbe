import XCTest

@testable import Orbe

/// 部品のグラフ——通る組み合わせ・役割・地図の並び・何をするかが変わった部品。
///
/// 壊れると何が起きるか: Issue の形の自動化が登録できない。ツールを持つ agent が処理や判定と導かれ、外の文面がツールを持つ
/// agent の依頼文に入る。地図で入力の部品が下に描かれ線が逆流する。名前や予定を直しただけで走っている回が止まる、または
/// 指示文を直しても前の中身で走り続ける。
final class AutomationGraphTests: OrbeTestCase {
  static let tool = "mcp__slack__post"
  static let everyTenMinutes = AutomationPart.Trigger.scheduled(.every(600))

  /// 入力の無いコマンドの、取得の部品。
  static func fetch(
    _ key: String, _ coverage: AutomationCoverage = .currentSet,
    trigger: AutomationPart.Trigger = everyTenMinutes
  ) -> AutomationPart {
    AutomationPart(
      key: key, name: key, trigger: trigger, inputs: [],
      method: .command(BackgroundCommand(script: "fetch \(key)", directory: nil)),
      timeoutMinutes: nil, coverage: coverage, destination: .nextPart, inboxLimit: nil)
  }

  static func agent(
    _ key: String, from inputs: [String] = [], tools: [String] = [],
    deliver: AutomationPart.Destination = .report, coverage: AutomationCoverage? = nil,
    trigger: AutomationPart.Trigger = .manual
  ) -> AutomationPart {
    AutomationPart(
      key: key, name: key, trigger: trigger, inputs: inputs,
      method: .agent(
        AutomationPartAgent(cli: "claude", model: nil, tools: tools, instruction: "\(key) して")),
      timeoutMinutes: nil, coverage: coverage, destination: deliver, inboxLimit: nil)
  }

  static func command(
    _ key: String, from inputs: [String] = [], deliver: AutomationPart.Destination = .sideEffect,
    trigger: AutomationPart.Trigger = .manual
  ) -> AutomationPart {
    AutomationPart(
      key: key, name: key, trigger: trigger, inputs: inputs,
      method: .command(BackgroundCommand(script: "run \(key)", directory: nil)),
      timeoutMinutes: nil, coverage: nil, destination: deliver, inboxLimit: nil)
  }

  /// Issue の動機の例と、今の 4 種の写し方の表の各行は通る。
  func testTheShapesFromTheIssuePass() throws {
    let nineEveryDay = AutomationPart.Trigger.scheduled(.cron(try BackgroundCron("0 9 * * *")))
    let sources = ["gh-prs", "backlog", "slack_dm"]
    let shapes: [(String, [AutomationPart])] = [
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
          Self.fetch("f"), Self.agent("p", from: ["f"], deliver: .nextPart, trigger: .arrival),
          Self.agent("j", from: ["p"], deliver: .taskCandidates, trigger: .arrival),
        ]
      ),
      ("入力の無いコマンド", [Self.command("c", trigger: Self.everyTenMinutes)]),
      (
        "取得 → 処理 → コマンド",
        [
          Self.fetch("f"), Self.agent("p", from: ["f"], deliver: .nextPart, trigger: .arrival),
          Self.command("c", from: ["p"], trigger: .arrival),
        ]
      ),
      (
        "取得（毎回全件）→ 報告",
        [Self.fetch("f", .everything), Self.agent("r", from: ["f"], trigger: .arrival)]
      ),
      ("ツールを持つ agent", [Self.agent("w", tools: [Self.tool], trigger: Self.everyTenMinutes)]),
      (
        "毎回全件の取得を合図にだけ使うツールを持つ agent の項目を判定する",
        [
          Self.fetch("f", .everything),
          Self.agent(
            "gate", from: ["f"], tools: [Self.tool], deliver: .nextPart, coverage: .newArrivals),
          Self.agent("j", from: ["gate"], deliver: .taskCandidates),
        ]
      ),
    ]
    for (label, parts) in shapes {
      XCTAssertNoThrow(try AutomationGraph(parts), label)
    }
  }

  /// 役割は部品自身の欄（入力・ツール・行き先）から Issue の役割の表どおりに導かれる。入力を合図にだけ使うツールを持つ agent は
  /// 行を見ないので取得。
  func testRolesFollowEachPartsOwnFields() throws {
    let graph = try AutomationGraph([
      Self.fetch("fetch"),
      Self.agent(
        "gate", from: ["fetch"], tools: [Self.tool], deliver: .nextPart, coverage: .newArrivals),
      Self.agent("process", from: ["fetch"], deliver: .nextPart),
      Self.command("processCommand", from: ["fetch"], deliver: .nextPart),
      Self.agent("judge", from: ["gate", "process", "processCommand"], deliver: .taskCandidates),
      Self.agent("report", from: ["fetch"]),
      Self.agent("reportAlone"),
      Self.agent("work", from: ["fetch"], tools: [Self.tool]),
      Self.command("sideEffect", from: ["fetch"]),
    ])

    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.key, $0.role) }),
      [
        "fetch": .fetch(.currentSet), "gate": .fetch(.newArrivals), "process": .process,
        "processCommand": .process, "judge": .judge, "report": .report, "reportAlone": .report,
        "work": .work, "sideEffect": .sideEffect,
      ])
  }

  /// 地図の並びは入力の深さ順（深さは最も長い道で数える）で、同じ深さは定義の順。入力の部品がいつも先に並ぶ。
  func testPartsLineUpByInputDepthThenDefinitionOrder() throws {
    let graph = try AutomationGraph([
      Self.agent("r", from: ["a", "p"]),
      Self.agent("p", from: ["b"], deliver: .nextPart),
      Self.fetch("b"),
      Self.fetch("a"),
    ])

    XCTAssertEqual(graph.byDepth.map(\.key), ["b", "a", "p", "r"])
  }

  /// 何をするか（手段・指示文・解いたモデル・ツール・解いた上限・入力・行き先）が変わった部品だけが挙がる。名前・予定・取得の
  /// 性質・溜まりの上限だけの変化、省略から同じ値の明示への変化、入力の順、足した部品・消した部品は挙がらない。
  func testOnlyPartsWhoseWorkChangedAreReworked() throws {
    let base = [Self.fetch("f1"), Self.fetch("f2"), Self.agent("r", from: ["f1", "f2"])]
    func changing(_ index: Int, _ change: (inout AutomationPart) -> Void) -> [AutomationPart] {
      var parts = base
      change(&parts[index])
      return parts
    }
    func changingAgent(_ change: (inout AutomationPartAgent) -> Void) -> [AutomationPart] {
      changing(2) {
        guard case .agent(var agent) = $0.method else { return }
        change(&agent)
        $0.method = .agent(agent)
      }
    }
    let unchanged: [String] = []
    let cases = [
      (
        "名前と予定",
        changing(2) {
          $0.name = "別名"; $0.trigger = Self.everyTenMinutes
        }, unchanged
      ),
      ("取得の性質", changing(0) { $0.coverage = .newArrivals }, unchanged),
      ("溜まりの上限", changing(2) { $0.inboxLimit = .init(maxAgeHours: 1, maxItems: nil) }, unchanged),
      ("報告の既定のモデルを明示", changingAgent { $0.model = "sonnet" }, unchanged),
      ("agent の既定の上限を明示", changing(2) { $0.timeoutMinutes = 10 }, unchanged),
      ("入力の順", changing(2) { $0.inputs = ["f2", "f1"] }, unchanged),
      ("部品を足す", base + [Self.command("s", trigger: Self.everyTenMinutes)], unchanged),
      ("指示文", changingAgent { $0.instruction = "別の指示" }, ["r"]),
      ("モデル", changingAgent { $0.model = "opus" }, ["r"]),
      ("ツール", changingAgent { $0.tools = [Self.tool] }, ["r"]),
      ("上限", changing(2) { $0.timeoutMinutes = 9 }, ["r"]),
      ("行き先", changing(2) { $0.destination = .taskCandidates }, ["r"]),
      (
        "コマンド",
        changing(0) { $0.method = .command(BackgroundCommand(script: "other", directory: nil)) },
        ["f1"]
      ),
      (
        "作業ディレクトリ",
        changing(0) {
          $0.method = .command(BackgroundCommand(script: "fetch f1", directory: "/a"))
        },
        ["f1"]
      ),
      ("入力を減らし、部品を消す", [base[0], Self.agent("r", from: ["f1"])], ["r"]),
    ]

    let old = try AutomationGraph(base)
    for (label, parts, reworked) in cases {
      XCTAssertEqual(
        AutomationGraph.reworked(from: old, to: try AutomationGraph(parts)), reworked, label)
    }
  }
}
