import XCTest

/// 配布物の hook 定義（`app/agent-plugin/`）の event→(matcher, state) 配線を契約として固定する。
/// テストは同梱物でなくリポジトリ実体の JSON を直接読む（`CompletionShimTests` と同じ形）。
/// 状態は各 CLI が持つフックの粒度で決まるため、期待表は CLI ごとに別に持つ。
final class AgentHookWiringTests: OrbeTestCase {
  /// このファイル: <repo>/Tests/OrbeTests/...swift → 3 階層上が repo root。
  private static let pluginRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // OrbeTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root
    .appendingPathComponent("app/agent-plugin/plugins/orbe-agent")

  /// hook 1 エントリ = (matcher, 報告する state)。`matcher` キーを持たないエントリは nil。
  private struct Entry: Equatable, CustomStringConvertible {
    let matcher: String?
    let state: String
    var description: String { "\(matcher ?? "*")→\(state)" }
  }

  // MARK: claude

  /// claude の event→(matcher, state) 全体が期待表と一致する。
  func testClaudeWiring() throws {
    XCTAssertEqual(
      try wiring("hooks/claude-hooks.json"),
      [
        "SessionStart": [Entry(matcher: nil, state: "idle")],
        "UserPromptSubmit": [Entry(matcher: nil, state: "working")],
        "Notification": [
          Entry(matcher: "permission_prompt|worker_permission_prompt", state: "waiting")
        ],
        "PreToolUse": [Entry(matcher: "AskUserQuestion|ExitPlanMode", state: "waiting")],
        "PostToolUse": [Entry(matcher: "AskUserQuestion|ExitPlanMode", state: "working")],
        "PostToolBatch": [Entry(matcher: nil, state: "working")],
        "Stop": [Entry(matcher: nil, state: "done")],
        "SessionEnd": [Entry(matcher: nil, state: "clear")],
      ])
  }

  /// ツールの待ちは PreToolUse / PostToolUse の同一 matcher が対で立て/解除する。
  /// 待つツールが事前に確定しているので matcher で正確に撃て、応答の瞬間に解除できる。
  func testToolWaitIsMatchedOnBothSides() throws {
    let claude = try wiring("hooks/claude-hooks.json")
    XCTAssertEqual(
      try XCTUnwrap(claude["PreToolUse"]).map(\.matcher),
      try XCTUnwrap(claude["PostToolUse"]).map(\.matcher))
  }

  /// PostToolUse に matcher 無しのエントリを置かない。matcher 無し（catch-all）は
  /// 待っているツールと並列に走る無関係なツールの完了でも撃たれ、waiting を潰す。
  func testPostToolUseHasNoCatchAllEntry() throws {
    let entries = try XCTUnwrap(try wiring("hooks/claude-hooks.json")["PostToolUse"])
    XCTAssertFalse(entries.contains { $0.matcher == nil })
  }

  /// permission の待ちはバッチ境界で解除する。どのツールが承認されるか事前に分からないため
  /// per-tool の matcher では撃てない。PostToolBatch は matcher の概念を持たないイベントなので、
  /// どのエントリも matcher キーを持たない。
  func testPostToolBatchIsWiredWithoutMatcher() throws {
    let entries = try XCTUnwrap(try wiring("hooks/claude-hooks.json")["PostToolBatch"])
    XCTAssertFalse(entries.isEmpty)
    XCTAssertTrue(entries.allSatisfy { $0.matcher == nil })
  }

  // MARK: codex / agy

  /// codex は working / waiting / done のみ。
  func testCodexWiring() throws {
    XCTAssertEqual(
      try wiring("hooks/codex-hooks.json"),
      [
        "UserPromptSubmit": [Entry(matcher: nil, state: "working")],
        "PermissionRequest": [Entry(matcher: nil, state: "waiting")],
        "Stop": [Entry(matcher: nil, state: "done")],
      ])
  }

  /// agy は working / done のみ。定義の形が claude / codex と違い、プラグイン名直下に event を持つ。
  func testAgyWiring() throws {
    let root = try json("hooks.json")
    let hooks = try XCTUnwrap(root["orbe-agent"] as? [String: [[String: Any]]])
    XCTAssertEqual(
      hooks.mapValues { $0.map { Entry(matcher: nil, state: state(ofCommand: $0["command"])) } },
      [
        "PreInvocation": [Entry(matcher: nil, state: "working")],
        "Stop": [Entry(matcher: nil, state: "done")],
      ])
  }

  /// 各定義は**自分の CLI 名**をシムへ渡す。3 ファイルはほぼ同形で、エントリの追加は既存行の
  /// コピペで進むため、`codex-hooks.json` に `claude` が紛れ込む類の取り違えが起きうる。
  /// 渡した名は `report_agent {agent}` → タブの agent 同一性（command）に入り resume コマンドの構築に
  /// 使われるので、取り違えると resume が別 CLI で立ち上がる。
  func testEachDefinitionPassesItsOwnAgentName() throws {
    for (path, expected) in [
      ("hooks/claude-hooks.json", "claude"), ("hooks/codex-hooks.json", "codex"),
    ] {
      let hooks = try XCTUnwrap(try json(path)["hooks"] as? [String: [[String: Any]]])
      for (event, groups) in hooks {
        for group in groups {
          let command = (group["hooks"] as? [[String: Any]])?.first?["command"]
          XCTAssertEqual(agent(ofCommand: command), expected, "\(path) の \(event)")
        }
      }
    }
    let agy = try XCTUnwrap(try json("hooks.json")["orbe-agent"] as? [String: [[String: Any]]])
    for (event, groups) in agy {
      for group in groups {
        XCTAssertEqual(agent(ofCommand: group["command"]), "agy", "hooks.json の \(event)")
      }
    }
  }

  // MARK: 読み取り

  /// claude / codex 形式（`{"hooks": {event: [{matcher?, hooks: [{command}]}]}}`）を読む。
  private func wiring(_ relativePath: String) throws -> [String: [Entry]] {
    let hooks = try XCTUnwrap(try json(relativePath)["hooks"] as? [String: [[String: Any]]])
    return hooks.mapValues { groups in
      groups.map { group in
        Entry(
          matcher: group["matcher"] as? String,
          state: state(ofCommand: (group["hooks"] as? [[String: Any]])?.first?["command"]))
      }
    }
  }

  private func json(_ relativePath: String) throws -> [String: Any] {
    let data = try Data(contentsOf: Self.pluginRoot.appendingPathComponent(relativePath))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// シム呼び出し（`... orbe-agent-status.sh <agent> <state>`）の末尾トークンが報告する state。
  private func state(ofCommand command: Any?) -> String {
    String((command as? String)?.split(separator: " ").last ?? "")
  }

  /// 同じシム呼び出しの末尾から 2 番目のトークン＝報告元の CLI 名（`<agent>`）。
  private func agent(ofCommand command: Any?) -> String {
    let tokens = (command as? String)?.split(separator: " ") ?? []
    return tokens.count >= 2 ? String(tokens[tokens.count - 2]) : ""
  }
}
