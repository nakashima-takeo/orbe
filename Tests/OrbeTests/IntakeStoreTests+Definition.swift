import XCTest

@testable import Orbe

/// 受信のストアの定義の検証と書き換え。
extension IntakeStoreTests {
  func testCreateTrimsTheNameAndNumbersWithoutReuse() throws {
    let store = IntakeStore(file: nil)
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
    codex.judge.cli = "codex"
    var noTools = Self.definition()
    noTools.fetch.method = .agent(
      IntakeAgentFetch(cli: "claude", model: "haiku", tools: [], request: "x"))
    var relative = Self.definition()
    relative.fetch.method = .command(BackgroundCommand(script: "x", directory: "tmp"))
    var tooOften = Self.definition()
    tooOften.when = .every(30)

    for (label, definition) in [
      ("複数行の名前", multiline), ("裏で回せない agent", codex), ("ツールの無い取得役", noTools),
      ("相対の作業ディレクトリ", relative), ("1 分より短い間隔", tooOften),
    ] {
      XCTAssertThrowsError(try store.replace(1, with: definition), label) {
        guard case .invalid = $0 as? IntakeError else { return XCTFail("\(label): \($0)") }
      }
    }
    XCTAssertEqual(store.intake(1)?.definition, Self.definition("受信 1"))
  }

  /// 取得役は外から届いた文面を読むので、使えるツールは名指しした MCP のツールだけ。組み込み・サーバー単位・
  /// ワイルドカードを通すと、文面に仕込まれた指示でファイルの書き込みや他のツールの呼び出しが起きうる。
  func testFetchAgentToolsMustBeFullMCPToolNames() throws {
    let store = try store()
    func fetching(_ tools: [String]) -> IntakeDefinition {
      var definition = Self.definition()
      definition.fetch.method = .agent(
        IntakeAgentFetch(cli: "claude", model: "haiku", tools: tools, request: "DM"))
      return definition
    }

    for tool in [
      "Read", "Bash", "mcp__slack", "mcp__slack__", "mcp____search", "mcp__*", "mcp__slack__*",
    ] {
      XCTAssertThrowsError(
        try store.replace(1, with: fetching(["mcp__slack__search", tool])), tool
      ) {
        guard case .invalid(let message) = $0 as? IntakeError else {
          return XCTFail("\(tool): \($0)")
        }
        XCTAssertTrue(message.contains(tool), "断る理由に名前を出す: \(message)")
      }
    }
    XCTAssertNoThrow(
      try store.replace(1, with: fetching(["mcp__plugin_core_backlog__get_issues"])),
      "サーバー名に _ を含む完全名は通す")
  }

  /// 取得か判定の書き換えだけが、次の回の全件見直しを立てる。名前やいつだけでは立てない。
  func testReplacingFetchOrJudgeMarksReviewAll() throws {
    let store = try store()
    var renamed = Self.definition("新しい名前", when: .every(600))

    XCTAssertFalse(try store.replace(1, with: renamed).reworked)
    XCTAssertFalse(store.intake(1)!.reviewAll)

    renamed.judge.instruction = "別の指示"
    XCTAssertTrue(try store.replace(1, with: renamed).reworked)
    XCTAssertTrue(store.intake(1)!.reviewAll)
  }
}
