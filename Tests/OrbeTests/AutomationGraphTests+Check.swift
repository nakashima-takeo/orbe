import XCTest

@testable import Orbe

/// グラフの検証の断り。断りの文は定義の中の場所（`parts[1].from` など）で始まり、AI はそこを直して送り直す。
///
/// 壊れると何が起きるか: 一度も走らない部品・行の行き場の無い部品・判定に行の届かない形が登録される。裸の Bash や Write を
/// 名指しした agent が何でもできる。毎回すべてを取るつながりの行から候補が作られ、同じ項目が回ごとに判定へ届く。今の集合の
/// 処理が入力の一部だけを写して、残りの出力を無効にする。
extension AutomationGraphTests {
  private func assertRefused(
    _ parts: [AutomationDefinition.Node], at place: String, _ label: String, line: UInt = #line
  ) {
    XCTAssertThrowsError(try AutomationGraph.check(parts), label, line: line) {
      guard case .invalid(let message) = $0 as? AutomationError else {
        return XCTFail("\(label): \($0)", line: line)
      }
      XCTAssertTrue(message.hasPrefix("\(place): "), "\(label): \(message)", line: line)
    }
  }

  /// 取得 f（parts[0]）と、f を入力にする報告の agent r（parts[1]）の片方を変える。
  private func changing(
    _ index: Int, _ change: (inout AutomationDefinition.Node) -> Void
  ) -> [AutomationDefinition.Node] {
    var parts = [Self.fetch("f"), Self.agent("r", from: ["f"])]
    change(&parts[index])
    return parts
  }

  private func changingAgent(_ change: (inout AutomationNodeAgent) -> Void)
    -> [AutomationDefinition.Node]
  {
    changing(1) {
      guard case .agent(var agent) = $0.action.method else { return }
      change(&agent)
      $0.action.method = .agent(agent)
    }
  }

  /// 部品自身の欄だけで決まる規則は、その部品の欄を指して断る。
  func testAPartsOwnFieldsAreRefusedAtTheirPlace() {
    let command = { (script: String, directory: String?) in
      AutomationActionDef.Method.command(BackgroundCommand(script: script, directory: directory))
    }
    for (label, parts, place) in [
      ("部品が 0 個", [AutomationDefinition.Node](), "parts"),
      ("鍵が空", changing(1) { $0.key = "" }, "parts[1].key"),
      ("鍵が 33 字", changing(1) { $0.key = String(repeating: "a", count: 33) }, "parts[1].key"),
      ("鍵に空白", changing(1) { $0.key = "a b" }, "parts[1].key"),
      ("鍵に英数字以外", changing(1) { $0.key = "取得" }, "parts[1].key"),
      ("名前が 2 行", changing(1) { $0.name = "a\nb" }, "parts[1].name"),
      ("1 分未満の間隔", changing(0) { $0.trigger = .scheduled(.every(30)) }, "parts[0].trigger"),
      ("空のコマンド", changing(0) { $0.action.method = command(" ", nil) }, "parts[0].command"),
      (
        "相対の作業ディレクトリ", changing(0) { $0.action.method = command("x", "tmp") },
        "parts[0].directory"
      ),
      ("裏で回せない CLI", changingAgent { $0.cli = "codex" }, "parts[1].agent"),
      ("知らない CLI", changingAgent { $0.cli = "nope" }, "parts[1].agent"),
      ("空のモデル", changingAgent { $0.model = " " }, "parts[1].model"),
      ("空の指示文", changingAgent { $0.instruction = " \n" }, "parts[1].instruction"),
      ("上限が 0 分", changing(1) { $0.action.timeoutMinutes = 0 }, "parts[1].timeoutMinutes"),
      ("上限が 61 分", changing(1) { $0.action.timeoutMinutes = 61 }, "parts[1].timeoutMinutes"),
      (
        "入力に同じ鍵が 2 度",
        changing(1) { $0.from = [.init(part: "f"), .init(part: "f", take: .all)] }, "parts[1].from"
      ),
      ("入力の無い部品の件数の上限", changing(0) { $0.maxItems = 1 }, "parts[0].maxItems"),
      ("件数の上限が 0", changing(1) { $0.maxItems = 0 }, "parts[1].maxItems"),
      (
        "古さの上限が 0", changing(1) { $0.from = [.init(part: "f", maxAgeHours: 0)] },
        "parts[1].from[0].maxAgeHours"
      ),
      ("入力の無い部品が届いたら", changing(0) { $0.trigger = .arrival }, "parts[0].trigger"),
      (
        "ツールを持つ agent がタスク候補へ",
        changing(1) {
          $0 = Self.agent("r", from: ["f"], tools: [Self.tool], deliver: .taskCandidates)
        }, "parts[1].deliver"
      ),
      (
        "入力の無い部品がタスク候補へ",
        [Self.agent("j", deliver: .taskCandidates)], "parts[0].deliver"
      ),
      (
        "agent の行き先が副作用だけ", changing(1) { $0.action.destination = .sideEffect },
        "parts[1].deliver"
      ),
      ("取得の部品に性質が無い", changing(0) { $0.action.coverage = nil }, "parts[0].coverage"),
      ("行を出さない部品に性質", changing(1) { $0.action.coverage = .currentSet }, "parts[1].coverage"),
    ] {
      assertRefused(parts, at: place, label)
    }
  }

  /// agent が名指せるのは MCP のツールの完全名と `Bash(<コマンドの接頭>:*)` だけ。組み込み・サーバー単位・ワイルドカードを通すと、
  /// 外の文面に仕込まれた指示でファイルの書き込みや名指しの外のツールの呼び出しが起きうる。Read を名指すと許可の規則に入り、
  /// 作業ディレクトリの外まで読める。
  func testAgentToolsMustBeFullMCPToolNamesOrBashRules() {
    let working = { (tool: String) in
      [Self.agent("w", tools: ["mcp__slack__search", tool], trigger: Self.everyTenMinutes)]
    }
    for tool in [
      "Bash", "Read", "Write", "mcp__slack", "mcp__slack__", "mcp____search", "mcp__slack__*",
      "mcp__slack__a b", "mcp__slack__search,mcp__slack", "Bash(*)", "Bash(gh:*", "Bash( :*)",
      "Bash(gh,curl:*)", "Bash(gh*:*)", "Bash(gh (x):*)", "Bash(gh\n:*)", "Bash(gh search prs)",
    ] {
      assertRefused(working(tool), at: "parts[0].tools", tool)
    }
    for tool in ["mcp__plugin_core_backlog__get_issues", "Bash(gh search prs:*)"] {
      XCTAssertNoThrow(try AutomationGraph.check(working(tool)), tool)
    }
  }

  /// 部品どうしの組み合わせの規則は、直すべき部品の欄を指して断る。
  func testCombinationsAreRefusedAtThePartToFix() {
    let unknown = [Self.fetch("f"), Self.agent("r", from: ["gh"])]
    XCTAssertThrowsError(try AutomationGraph.check(unknown)) {
      XCTAssertEqual($0 as? AutomationError, .invalid(#"parts[1].from: unknown part "gh""#))
    }

    for (label, parts, place) in [
      (
        "鍵の重複は 2 つ目を指す",
        [Self.fetch("f"), Self.agent("r", from: ["f"]), Self.agent("r", from: ["f"])],
        "parts[2].key"
      ),
      (
        "循環は定義の順で最初に輪に乗る部品を指す",
        [
          Self.fetch("f"), Self.agent("a", from: ["f", "b"], deliver: .nextPart),
          Self.agent("b", from: ["a"], deliver: .nextPart), Self.agent("r", from: ["b"]),
        ], "parts[1].from"
      ),
      (
        "行き先が次の部品なのに誰も名指さない",
        [Self.fetch("f"), Self.fetch("g"), Self.agent("r", from: ["f"])], "parts[1].deliver"
      ),
      (
        "行き先が次の部品でない部品を名指すのは名指した側を指す",
        [Self.fetch("f"), Self.agent("r", from: ["f"]), Self.agent("x", from: ["r"])],
        "parts[2].from"
      ),
      (
        "毎回すべてを取るつながりの行が処理を通って判定へ届く",
        [
          Self.fetch("f"), Self.taking(.all, Self.agent("p", from: ["f"], deliver: .nextPart)),
          Self.agent("j", from: ["p"], deliver: .taskCandidates),
        ], "parts[1].from[0]"
      ),
      (
        "判定が毎回すべてを取る",
        [
          Self.fetch("f"),
          Self.taking(.all, Self.agent("j", from: ["f"], deliver: .taskCandidates)),
        ],
        "parts[1].from[0]"
      ),
      (
        "今の集合の処理が新しい行だけを取る",
        [
          Self.fetch("f"), Self.agent("p", from: ["f"], deliver: .nextPart, coverage: .currentSet),
          Self.agent("r", from: ["p"]),
        ], "parts[1].from[0]"
      ),
      (
        "今の集合の処理が件数の上限を持つ",
        {
          var process = Self.taking(
            .all, Self.agent("p", from: ["f"], deliver: .nextPart, coverage: .currentSet))
          process.maxItems = 5
          return [Self.fetch("f"), process, Self.agent("r", from: ["p"])]
        }(), "parts[1].maxItems"
      ),
    ] {
      assertRefused(parts, at: place, label)
    }
  }
}
