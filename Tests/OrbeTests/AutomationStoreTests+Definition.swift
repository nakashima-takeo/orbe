import XCTest

@testable import Orbe

/// 受信のストアの定義の検証と書き換え。
extension AutomationStoreTests {
  func testCreateTrimsTheNameAndNumbersWithoutReuse() throws {
    let store = AutomationStore(file: nil)
    let first = try store.create(Self.definition("  GitHub: レビュー依頼 "), now: t0)
    try store.delete(first.id)
    let second = try store.create(Self.definition(), now: t0)

    XCTAssertEqual(first.definition.name, "GitHub: レビュー依頼")
    XCTAssertEqual(second.id, first.id + 1, "消した ID を使い回さない")
  }

  func testInvalidDefinitionsAreRejectedAndChangeNothing() throws {
    let store = try store()
    var multiline = Self.definition()
    multiline.name = "a\nb"
    var codex = Self.definition()
    codex.steps = [Self.judgeStep(cli: "codex")]
    var noTools = Self.definition()
    noTools.source?.method = Self.agentSource(tools: [])
    var relative = Self.definition()
    relative.source?.method = .command(BackgroundCommand(script: "x", directory: "tmp"))
    var tooOften = Self.definition()
    tooOften.trigger = .every(30)
    var noSource = Self.definition()
    noSource.source = nil
    let everything = Self.definition(coverage: .everything)
    var noSteps = Self.definition()
    noSteps.steps = []

    for (label, definition) in [
      ("複数行の名前", multiline), ("裏で回せない agent", codex), ("ツールの無い取得役", noTools),
      ("相対の作業ディレクトリ", relative), ("1 分より短い間隔", tooOften),
      ("取得元の無いタスク候補", noSource), ("毎回全件のタスク候補", everything), ("段の無いタスク候補", noSteps),
    ] {
      XCTAssertThrowsError(try store.replace(1, with: definition), label) {
        guard case .invalid = $0 as? AutomationError else { return XCTFail("\(label): \($0)") }
      }
    }
    XCTAssertEqual(store.automation(1)?.definition, Self.definition("受信 1"))
  }

  /// 取得役は外から届いた文面を読むので、使えるツールは名指しした MCP のツールだけ。組み込み・サーバー単位・
  /// ワイルドカードを通すと、文面に仕込まれた指示でファイルの書き込みや他のツールの呼び出しが起きうる。
  func testFetchAgentToolsMustBeFullMCPToolNames() throws {
    let store = try store()
    func fetching(_ tools: [String]) -> AutomationDefinition {
      var definition = Self.definition()
      definition.source?.method = Self.agentSource(tools: tools)
      return definition
    }

    for tool in [
      "Read", "Bash", "mcp__slack", "mcp__slack__", "mcp____search", "mcp__*", "mcp__slack__*",
      "mcp__slack__search,mcp__slack", "mcp__slack__a b",
    ] {
      XCTAssertThrowsError(
        try store.replace(1, with: fetching(["mcp__slack__search", tool])), tool
      ) {
        guard case .invalid(let message) = $0 as? AutomationError else {
          return XCTFail("\(tool): \($0)")
        }
        XCTAssertTrue(message.contains(tool), "断る理由に名前を出す: \(message)")
      }
    }
    XCTAssertNoThrow(
      try store.replace(1, with: fetching(["mcp__plugin_core_backlog__get_issues"])),
      "サーバー名に _ を含む完全名は通す")
  }

  /// 取得元か処理の書き換えだけが、次の回の全件見直しを立てる。名前・いつ・段の名前だけ、モデルを省略から同じ値の明示へ
  /// 変えただけでは立てない。
  func testReplacingFetchOrJudgeMarksReviewAll() throws {
    let store = try store()
    var renamed = Self.definition("新しい名前", trigger: .every(600))
    renamed.steps[0].name = "仕分け"

    XCTAssertFalse(try store.replace(1, with: renamed).reworked)
    XCTAssertFalse(store.automation(1)!.reviewAll)

    renamed.steps = [Self.judgeStep("別の指示")]
    XCTAssertTrue(try store.replace(1, with: renamed).reworked)
    XCTAssertTrue(store.automation(1)!.reviewAll)

    func judging(model: String?) -> AutomationDefinition {
      var definition = renamed
      definition.steps[0].method = .agent(
        AutomationStepAgent(cli: "claude", model: model, instruction: "別の指示"))
      return definition
    }
    _ = try store.replace(1, with: judging(model: nil))
    XCTAssertFalse(try store.replace(1, with: judging(model: "sonnet")).reworked)
  }
}
