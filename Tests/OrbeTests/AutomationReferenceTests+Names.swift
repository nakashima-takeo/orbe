import Foundation
import OrbeAutomationReference
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 自動化の説明が `` ` `` で囲んで名指す名前（欄名・値・ツール名・環境変数・CLI のフラグ）は今の形に実在し、定義が持てる欄はどれも
/// 定義の節に出ている。語彙は今の Orbe の実物（定義の書き出し・応答・`tools/list`・コマンドが受けた環境・`orb automation --help` の
/// usage）から集める。
///
/// 壊れると何が起きるか: 欄を改名・削除しても説明が古い名前のまま残り、AI が応答の中に無い欄を探して読めない、または定義に無い欄を
/// 書いて断られる。新しい欄を足しても説明に載らず、AI がその欄を使えない。
extension AutomationReferenceTests {
  /// 説明の囲んだ名前は、どれも今の形の語彙にある。
  func testEveryNameTheDescriptionsQuoteExists() throws {
    let vocabulary = try Self.vocabulary(self)
    let tools = ControlProcess.mcpToolsList().filter {
      ($0["name"] as? String)?.contains("automation") == true
    }
    let help = ControlProcess.orbWithoutServer(["automation", "--help"]).stdout
    let texts: [(String, String)] =
      [
        ("共有の英文", AutomationReference.sections.joined(separator: "\n\n")),
        ("orb automation --help", help),
        ("自動化のスキル", try String(contentsOf: Self.skill, encoding: .utf8)),
        ("自動化のスキルの型", try String(contentsOf: Self.patterns, encoding: .utf8)),
      ] + tools.map { ("\($0["name"] ?? "") の説明", Self.descriptions($0)) }

    for (label, text) in texts {
      for name in Self.quoted(in: text) {
        let parts = name.hasPrefix("--") ? [name] : name.split(separator: ".").map(String.init)
        for part in parts where !vocabulary.contains(part) {
          XCTFail("\(label)が今の形に無い名前 \(name) を名指ししている")
        }
      }
    }
  }

  /// 定義が持てる欄（省略できる欄を含む）は、どれも定義の節に囲んで出ている。
  func testEveryDefinitionFieldIsInTheDefinitionSection() {
    let fields = AutomationDefinition.keys.union(AutomationDefinition.Node.keys)
      .union(AutomationDefinition.Input.keys).union(AutomationNode.Trigger.keys)
    let quoted = Set(Self.quoted(in: AutomationReference.definition))

    for field in fields.subtracting(quoted).sorted() {
      XCTFail("定義の欄 \(field) が定義の節に無い")
    }
  }

  // MARK: - 語彙

  /// 今の形の語彙。応答（一覧・回の記録・候補・試走）・`tools/list`・コマンドが受けた環境・CLI の usage・応答に出ない値の列挙。
  static func vocabulary(_ test: AutomationReferenceTests) throws -> Set<String> {
    var words: Set<String> = []
    // 応答に出ない値（見本と試走が持たない種類）は列挙から足す。
    words.formUnion(AutomationNotify.allCases.map(\.rawValue))
    words.formUnion(AutomationDismissal.Why.allCases.map(\.rawValue))
    words.insert(AutomationTake.new.rawValue)
    words.insert(AutomationTrial.NodeState.untouched.rawValue)
    for tool in ControlProcess.mcpToolsList() {
      collect(tool["name"], strings: &words)
      collect((tool["inputSchema"] as? [String: Any])?["properties"], keys: &words)
    }
    words.formUnion(usageFlags())
    for response in try responses(test) {
      collect(response, keys: &words)
      collect(response, strings: &words)
    }
    return words
  }

  /// `orb automation --help` の usage の行が受けるフラグ。
  private static func usageFlags() -> Set<String> {
    let help = ControlProcess.orbWithoutServer(["automation", "--help"]).stdout
    let usage = help.components(separatedBy: "COMMANDS").first ?? ""
    return Set(
      usage.split(whereSeparator: { " []()|.\n".contains($0) }).map(String.init).filter {
        $0.hasPrefix("--")
      })
  }

  /// 版 2 の見本の DB（読めない定義・不明な記録・読めない候補を足したもの）で起こした Orbe の応答と、コマンドが受けた環境。
  private static func responses(_ test: AutomationReferenceTests) throws -> [Any] {
    try FileManager.default.createDirectory(
      at: test.automationsFolder(), withIntermediateDirectories: true)
    try SQLiteDatabase(url: test.automationsFolder().appendingPathComponent("db.sqlite")).exec(
      AutomationVersionTwoFixture.schema + "\n" + AutomationVersionTwoFixture.rows + "\n"
        + unreadableRows + "\nPRAGMA user_version = 2;")
    let wc = try test.launch()
    var responses: [Any] = [
      try test.success(wc.controlListAutomations()),
      try test.success(
        wc.controlListAutomationRuns(automationId: 1, nodeKey: nil, before: nil, limit: nil)),
      try test.success(
        wc.controlListAutomationRuns(automationId: 1, nodeKey: nil, before: nil, limit: 1)),
      try test.success(wc.controlListAutomationProposals(automationId: nil)),
    ]
    responses += try trials(test, wc)
    responses.append(try environment(test, wc))
    return responses
  }

  /// 読めない定義（自動化 2）・不明な記録（回 13）・読めない候補（候補 5）。
  private static let unreadableRows = """
    INSERT INTO node_defs VALUES(8,'action');
    INSERT INTO action_defs VALUES(8,'action','{"model":"sonnet","instruction":1}');
    INSERT INTO automations VALUES(2,'読めない','menuBar',NULL,NULL,1,1793000000000);
    INSERT INTO nodes VALUES(8,2,0,'fetch','取る','{"kind":"manual"}',NULL,NULL,8,1793000000000,\
    NULL,NULL,NULL,0,0,'{}');
    INSERT INTO runs VALUES(13,1,1,1793003720000,1793003780000,'schedule',NULL,'{}');
    INSERT INTO items VALUES(4,1,6,'d',NULL,NULL,1793001860000,NULL,NULL);
    INSERT INTO item_versions VALUES(5,4,6,'{"body":"課題 d","id":"d","link":"https://example.com/d"}',\
    1793001860000);
    UPDATE nodes SET last_item_seq = 6 WHERE id = 1;
    INSERT INTO proposals VALUES(5,10,4,5,NULL,'https://example.com/d','d を見る','x',NULL,NULL);
    INSERT INTO held_proposals VALUES(5,4,'https://example.com/d',NULL);
    """

  /// 試走 2 つ: 書き換えの試走（書いた時点の回・与えた行・判定の案・止めた副作用）と、時間切れの待ち。
  private static func trials(_ test: AutomationReferenceTests, _ wc: WindowController) throws
    -> [Any]
  {
    let fetch: [String: Any] = [
      "key": "fetch", "name": "取る", "trigger": ["kind": "manual"], "command": "true",
      "coverage": "currentSet",
    ]
    let send: [String: Any] = [
      "key": "send", "name": "送る", "trigger": ["kind": "arrival"], "from": ["fetch"],
      "command": "cat >/dev/null", "deliver": "none",
    ]
    let written = try XCTUnwrap(
      test.success(
        wc.controlSetAutomation(
          automationId: nil, version: nil, ["name": "試す", "nodes": [fetch, send]]))[
          "automation"] as? [String: Any])
    let saved = try XCTUnwrap(written["automationId"] as? Int)
    let item = AutomationItem(id: "a", link: "https://example.com/a", body: "a", time: Date())
    try wc.automationStore.record(
      saved, nodeKey: "fetch", at: Date(), outcome: DesignSceneFixtures.fetched([item]))
    let fetchId = wc.automationStore.nodeId(saved, "fetch")
    var savedFetch = fetch
    savedFetch["id"] = fetchId.rawValue
    var savedSend = send
    savedSend["id"] = wc.automationStore.nodeId(saved, "send").rawValue
    let workspace = try XCTUnwrap(wc.workspaces.first?.id.uuidString)
    let judge: [String: Any] = [
      "key": "judge", "name": "判定", "trigger": ["kind": "arrival"], "from": ["fetch"],
      "deliver": "taskCandidates",
      "command": "cat >/dev/null; echo '{\"propose\":\"\(fetchId.rawValue):b\",\"title\":\"b\","
        + "\"due\":\"2026-12-01\",\"workspace\":\"\(workspace)\",\"reason\":\"r\"}'",
    ]
    let row = #"{"id":"b","link":"https://example.com/b","body":"b"}"#
    let rewrite = try started(
      test,
      wc.controlTryAutomation(
        automationId: saved, version: written["version"] as? Int,
        definition: ["name": "試す", "nodes": [savedFetch, judge, savedSend]],
        AutomationTrial.Request(rows: [row])))
    var slowFetch = fetch
    slowFetch["command"] = "sleep 2"
    let slow = try started(
      test,
      wc.controlTryAutomation(
        automationId: nil, version: nil, definition: ["name": "遅い", "nodes": [slowFetch, send]],
        .init()))
    return [
      try waited(test, wc, rewrite, timeoutMs: 10000), try waited(test, wc, slow, timeoutMs: 100),
    ]
  }

  private static func started(_ test: AutomationReferenceTests, _ result: Result<Any, ControlError>)
    throws -> Int
  {
    try XCTUnwrap((test.success(result)["trial"] as? [String: Any])?["trialId"] as? Int)
  }

  private static func waited(
    _ test: AutomationReferenceTests, _ wc: WindowController, _ trialId: Int, timeoutMs: Int
  ) throws -> [String: Any] {
    var reply: Result<Any, ControlError>?
    wc.controlAutomationTrial(trialId: trialId, wait: true, timeoutMs: timeoutMs) { reply = $0 }
    test.waitUntil(15) { reply != nil }
    return try test.success(try XCTUnwrap(reply))
  }

  /// 取得と副作用のコマンドが受けた環境変数の名前（2 回目の取得は前回の成功の目印を受ける）。
  private static func environment(_ test: AutomationReferenceTests, _ wc: WindowController) throws
    -> [String]
  {
    let file = TestScratch.caseDir.appendingPathComponent("env.txt").path
    let record = "env | grep '^ORBE_' >> '\(file)'"
    let definition: [String: Any] = [
      "name": "環境",
      "nodes": [
        [
          "key": "fetch", "name": "取る", "trigger": ["kind": "manual"],
          "command": "\(record); echo '{\"id\":\"a\",\"body\":\"a\"}'", "coverage": "newArrivals",
        ],
        [
          "key": "send", "name": "送る", "trigger": ["kind": "arrival"], "from": ["fetch"],
          "command": "\(record); cat >/dev/null", "deliver": "none",
        ],
      ],
    ]
    let id = try XCTUnwrap(
      (test.success(wc.controlSetAutomation(automationId: nil, version: nil, definition))[
        "automation"] as? [String: Any])?["automationId"] as? Int)
    func runs(_ key: String) -> Int {
      wc.automationStore.automation(id)?.state(key: key).runs.count ?? 0
    }
    _ = try test.success(wc.controlRunAutomation(automationId: id, nodeKey: nil))
    XCTAssertTrue(test.waitUntil(10) { runs("send") == 1 }, "前提: 副作用が 1 回実行される")
    _ = try test.success(wc.controlRunAutomation(automationId: id, nodeKey: "fetch"))
    XCTAssertTrue(test.waitUntil(10) { runs("fetch") == 2 }, "前提: 取得が 2 回実行される")
    let lines = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
    return lines.split(separator: "\n").compactMap {
      $0.split(separator: "=").first.map(String.init)
    }
  }

  // MARK: - 道具

  /// 実 `WindowController`（自動化の DB は呼ぶ前に置いたもの）。
  func launch() throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  func success(_ result: Result<Any, ControlError>) throws -> [String: Any] {
    switch result {
    case .success(let value): return try XCTUnwrap(value as? [String: Any])
    case .failure(let error): throw error
    }
  }

  /// 文の中で `` ` `` に囲まれた語（Markdown のコードブロックの中は除く）。
  static func quoted(in text: String) -> [String] {
    let prose = text.replacingOccurrences(
      of: "(?s)```.*?```", with: "", options: .regularExpression)
    return prose.split(separator: "\n", omittingEmptySubsequences: false).flatMap { line in
      line.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
    }
  }

  /// ツールの説明と、引数の説明。
  private static func descriptions(_ tool: [String: Any]) -> String {
    let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    return
      ([tool["description"] as? String ?? ""]
      + properties.values.compactMap { ($0 as? [String: Any])?["description"] as? String })
      .joined(separator: "\n")
  }

  /// JSON の値の、すべての鍵。
  static func collect(_ value: Any?, keys: inout Set<String>) {
    if let object = value as? [String: Any] {
      keys.formUnion(object.keys)
      object.values.forEach { collect($0, keys: &keys) }
    } else if let array = value as? [Any] {
      array.forEach { collect($0, keys: &keys) }
    }
  }

  /// JSON の値の、すべての文字列。
  static func collect(_ value: Any?, strings: inout Set<String>) {
    if let string = value as? String {
      strings.insert(string)
    } else if let object = value as? [String: Any] {
      object.values.forEach { collect($0, strings: &strings) }
    } else if let array = value as? [Any] {
      array.forEach { collect($0, strings: &strings) }
    }
  }

  /// 同梱の自動化のスキル（`skills/automation/SKILL.md`）。
  static let skill = patterns.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("SKILL.md")
}
