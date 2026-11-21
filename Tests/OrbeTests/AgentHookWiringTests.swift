import XCTest

@testable import Orbe

/// 配布物の hook 定義（`app/agent-plugin/`）が守る不変条件と、Orbe 本体との突き合わせ。
/// テストは同梱物でなくリポジトリ実体の JSON を直接読む（`CompletionShimTests` と同じ形）。
///
/// 壊れると何が起きるか: 待ちが無関係なイベントで立つか潰れる、報告がタブの状態にならない、
/// resume が別 CLI で立ち上がる、`spawn_agent` / `resume_agent` が来ない idle を待つ。
final class AgentHookWiringTests: OrbeTestCase {
  /// このファイル: <repo>/Tests/OrbeTests/...swift → 3 階層上が repo root。
  private static let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // OrbeTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root
    .appendingPathComponent("app/agent-plugin")

  /// hook 1 エントリ。`matcher` キーを持たないエントリは nil。`command` はシム呼び出し
  /// （`... orbe-agent-status.sh <agent> <state>`）。
  private struct Entry {
    let matcher: String?
    let command: String

    private var tokens: [Substring] { command.split(separator: " ") }
    /// 末尾トークン＝報告する state。
    var state: String { String(tokens.last ?? "") }
    /// 末尾から 2 番目のトークン＝報告元の CLI 名。
    var agent: String { tokens.count >= 2 ? String(tokens[tokens.count - 2]) : "" }
  }

  // MARK: 待ち

  /// permission の待ちは matcher で permission 系の通知に絞る。絞らないと無操作の idle 通知などでも
  /// 撃たれ、waiting を誤認する。
  func testPermissionNotificationIsNarrowedByMatcher() throws {
    let entries = try XCTUnwrap(try definitions()["claude"]?["Notification"])
    XCTAssertFalse(entries.isEmpty)
    XCTAssertTrue(entries.allSatisfy { $0.matcher != nil })
  }

  /// ツールの待ちは PreToolUse / PostToolUse の同一 matcher が対で立て/解除する（claude / agy）。
  /// 待つツールが事前に確定しているので matcher で正確に撃て、応答の瞬間に解除できる。
  func testToolWaitIsMatchedOnBothSides() throws {
    for cli in ["claude", "agy"] {
      let events = try XCTUnwrap(try definitions()[cli])
      XCTAssertEqual(
        try XCTUnwrap(events["PreToolUse"]).map(\.matcher),
        try XCTUnwrap(events["PostToolUse"]).map(\.matcher), cli)
    }
  }

  /// PostToolUse に matcher 無しのエントリを置かない（claude / agy）。matcher 無し（catch-all）は
  /// 待っているツールと並列に走る無関係なツールの完了でも撃たれ、waiting を潰す。
  func testPostToolUseHasNoCatchAllEntry() throws {
    for cli in ["claude", "agy"] {
      let entries = try XCTUnwrap(try definitions()[cli]?["PostToolUse"])
      XCTAssertFalse(entries.contains { $0.matcher == nil }, cli)
    }
  }

  /// agy の質問の待ちは、質問ツールの直前に立て、直後（答えてもスキップしても呼ばれる）に解く。
  func testAgyQuestionWaitIsRaisedBeforeAndClearedAfterTheQuestionTool() throws {
    let agy = try XCTUnwrap(try definitions()["agy"])
    let before = try XCTUnwrap(agy["PreToolUse"])
    let after = try XCTUnwrap(agy["PostToolUse"])
    XCTAssertEqual(before.map(\.matcher), ["ask_question"])
    XCTAssertEqual(before.map(\.state), ["waiting"])
    XCTAssertEqual(after.map(\.state), ["working"])
  }

  /// permission の待ちはバッチ境界で解除する。どのツールが承認されるか事前に分からないため
  /// per-tool の matcher では撃てない。PostToolBatch は matcher の概念を持たないイベントなので、
  /// どのエントリも matcher キーを持たない。
  func testPostToolBatchIsWiredWithoutMatcher() throws {
    let entries = try XCTUnwrap(try definitions()["claude"]?["PostToolBatch"])
    XCTAssertFalse(entries.isEmpty)
    XCTAssertTrue(entries.allSatisfy { $0.matcher == nil })
  }

  /// 起動時の idle は、会話が始まる・切り替わる source（起動・再開・/clear・fork）だけに絞る。compact も
  /// SessionStart を撃ち、自動 compact はターンの途中で走るので、絞らないと作業中の agent を idle と誤認して
  /// 次の入力を貼る。
  func testSessionStartIsNarrowedToConversationStarts() throws {
    let entries = try XCTUnwrap(try definitions()["claude"]?["SessionStart"])
    XCTAssertEqual(entries.map(\.matcher), ["startup|resume|clear|fork"])
  }

  /// API エラーで終わったターン（Stop の代わりに StopFailure）も、ターンの終わりとして done にする。配線しないと
  /// working のまま残り、会話へ貼ってよいタブにならない。ただし usage limit（`rate_limit`）は終わりにしない——claude は
  /// その場でリセットを待って自分で続けるので、done にすると待ちの間に解けた待ちの続きが貼られ、続きが打ち切られる。
  /// 待ちが続きなしに終わったこと（Notification の `quota_auto_resume_disabled`）を終わりとする。
  func testATurnThatEndsInAnAPIErrorIsDoneExceptAUsageLimit() throws {
    let claude = try XCTUnwrap(try definitions()["claude"])
    let failure = try XCTUnwrap(claude["StopFailure"])
    XCTAssertEqual(failure.map(\.state), ["done"])
    let kinds = try XCTUnwrap(failure.first?.matcher).split(separator: "|").map(String.init)
    XCTAssertTrue(kinds.contains("server_error"))
    XCTAssertFalse(kinds.contains("rate_limit"))
    let quota = try XCTUnwrap(claude["Notification"]).filter {
      $0.matcher == "quota_auto_resume_disabled"
    }
    XCTAssertEqual(quota.map(\.state), ["done"])
  }

  // MARK: Orbe 本体との突き合わせ

  /// 定義が報告する state は、どれも Orbe が状態として解する語（状態グリフの種別か、終わりの `clear`）。
  /// 綴りを違えた state はタブに知らない状態として載り、グリフも通知音も出ない。
  func testEveryReportedStateIsOneOrbeUnderstands() throws {
    let understood = Set(AgentStateIcon.Kind.allCases.map(\.state)).union(["clear"])
    for (cli, events) in try definitions() {
      for (event, entries) in events {
        for entry in entries {
          XCTAssertTrue(understood.contains(entry.state), "\(cli) の \(event): \(entry.state)")
        }
      }
    }
  }

  /// 起動時に idle を報告すると Orbe が数えている CLI（`spawn_agent` / `resume_agent` が ready を待つ）は、
  /// 定義が SessionStart に idle を配線している CLI とちょうど一致する。食い違うと、配線の無い CLI では
  /// 来ない idle を待ち、配線のある CLI では待たずに打鍵を送る。定義を持たない CLI は待たない。
  func testIdleOnStartMatchesTheCatalog() throws {
    let definitions = try definitions()
    for cli in AgentCatalog.supported {
      let events = try XCTUnwrap(definitions[cli], "\(cli) の hook 定義が無い")
      let wired = events["SessionStart"]?.contains { $0.state == "idle" } ?? false
      XCTAssertEqual(AgentCatalog.reportsIdleOnStart(cli), wired, cli)
    }
    XCTAssertFalse(AgentCatalog.reportsIdleOnStart("bash"))
  }

  /// 各定義は**自分の CLI 名**をシムへ渡す。3 ファイルはほぼ同形で、エントリの追加は既存行の
  /// コピペで進むため、`codex-hooks.json` に `claude` が紛れ込む類の取り違えが起きうる。
  /// 渡した名は `report_agent {agent}` → タブの agent 同一性（command）に入り resume コマンドの構築に
  /// 使われるので、取り違えると resume が別 CLI で立ち上がる。
  func testEachDefinitionPassesItsOwnAgentName() throws {
    for (cli, events) in try definitions() {
      for (event, entries) in events {
        for entry in entries {
          XCTAssertEqual(entry.agent, cli, "\(cli) の \(event)")
        }
      }
    }
  }

  // MARK: 読み取り

  /// CLI ごとの定義（event → エントリ）。claude / codex は
  /// `{"hooks": {event: [{matcher?, hooks: [{command}]}]}}`、agy はプラグイン名直下に event を置き、
  /// matcher を取る event（PreToolUse / PostToolUse）は `[{matcher, hooks: [{command}]}]`、取らない event は
  /// `[{command}]`。
  private func definitions() throws -> [String: [String: [Entry]]] {
    var out: [String: [String: [Entry]]] = [:]
    let files = [
      ("claude", "plugins/orbe-agent/hooks/claude-hooks.json"),
      ("codex", "codex/orbe-agent/hooks/codex-hooks.json"),
    ]
    for (cli, path) in files {
      let hooks = try XCTUnwrap(try json(path)["hooks"] as? [String: [[String: Any]]])
      out[cli] = hooks.mapValues { $0.map(Self.entry) }
    }
    let agy = try XCTUnwrap(
      try json("plugins/orbe-agent/hooks.json")["orbe-agent"] as? [String: [[String: Any]]])
    out["agy"] = agy.mapValues { $0.map(Self.entry) }
    return out
  }

  /// `hooks` を持つ要素は matcher つきの組、持たない要素は command そのもの。
  private static func entry(_ element: [String: Any]) -> Entry {
    guard let hooks = element["hooks"] as? [[String: Any]] else {
      return Entry(matcher: nil, command: element["command"] as? String ?? "")
    }
    return Entry(
      matcher: element["matcher"] as? String,
      command: hooks.first?["command"] as? String ?? "")
  }

  private func json(_ relativePath: String) throws -> [String: Any] {
    let data = try Data(contentsOf: Self.packageRoot.appendingPathComponent(relativePath))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
