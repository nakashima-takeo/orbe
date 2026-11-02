import Foundation

// 定義の JSON の形。読むときに断るのは形の誤り（知らない鍵を含む）だけで、値と組み合わせは `AutomationGraph` が検証する。
// 知らない鍵は、そのオブジェクトを読む入口が自分の欄で照らす。

/// 定義の JSON のオブジェクトの、受ける欄に無い鍵。場所は読みの誤りと同じく定義の中の場所で言う。
struct AutomationUnknownKey: Error {
  let codingPath: [CodingKey]
}

extension Decoder {
  /// このオブジェクトの鍵が `fields` の中だけかを照らす。オブジェクトでなければ読みの誤り。
  func checkKeys(_ fields: Set<String>) throws {
    let c = try container(keyedBy: AnyKey.self)
    if let unknown = c.allKeys.map(\.stringValue).sorted().first(where: { !fields.contains($0) }) {
      throw AutomationUnknownKey(codingPath: codingPath + [AnyKey(stringValue: unknown)])
    }
  }
}

private struct AnyKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

extension CaseIterable where Self: CodingKey {
  fileprivate static var names: Set<String> { Set(allCases.map(\.stringValue)) }
}

/// `workspace` は書けば UUID の文字列（`Workspace.id`）。
extension AutomationDefinition: Codable {
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case name, notify, workspace, nodes
  }

  init(from decoder: Decoder) throws {
    try decoder.checkKeys(CodingKeys.names)
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    notify = try c.decodeIfPresent(AutomationNotify.self, forKey: .notify)
    workspace = try c.decodeWorkspace(forKey: .workspace)
    nodes = try c.decode([Node].self, forKey: .nodes)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encodeIfPresent(notify, forKey: .notify)
    try c.encodeIfPresent(workspace, forKey: .workspace)
    try c.encode(nodes, forKey: .nodes)
  }
}

extension KeyedDecodingContainer {
  /// workspace の席。欄があれば UUID の文字列だけを受ける——`null` を「書かない」と同じに読むと、ノードの席では黙って自動化の
  /// workspace を継ぐ。`null`・UUID でない値は、どれも場所付きの読みの誤り。
  fileprivate func decodeWorkspace(forKey key: Key) throws -> UUID? {
    guard contains(key) else { return nil }
    guard let id = UUID(uuidString: try decode(String.self, forKey: key)) else {
      throw DecodingError.typeMismatch(
        UUID.self, .init(codingPath: codingPath + [key], debugDescription: "not a workspace id"))
    }
    return id
  }
}

/// ノードの欄と動作の定義の欄を 1 つのオブジェクトに並べる。`from` と agent の `tools` の空の配列は書かないのと同じ。受ける鍵は
/// ノードの欄と動作の定義の欄の和で、ノードの入口が照らす（動作の定義が自分で照らすと、同じオブジェクトのノードの欄を断る）。
extension AutomationDefinition.Node: Codable {
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case id, key, name, trigger, from, maxItems, retentionDays
  }

  init(from decoder: Decoder) throws {
    try decoder.checkKeys(CodingKeys.names.union(AutomationActionDef.keys))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(Int.self, forKey: .id).map(AutomationNodeID.init)
    key = try c.decode(String.self, forKey: .key)
    name = try c.decode(String.self, forKey: .name)
    trigger = try c.decode(AutomationNode.Trigger.self, forKey: .trigger)
    from = try c.decodeIfPresent([AutomationDefinition.Input].self, forKey: .from) ?? []
    action = try AutomationActionDef(from: decoder)
    maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems)
    retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(id?.rawValue, forKey: .id)
    try c.encode(key, forKey: .key)
    try c.encode(name, forKey: .name)
    try c.encode(trigger, forKey: .trigger)
    if !from.isEmpty { try c.encode(from, forKey: .from) }
    try action.encode(to: encoder)
    try c.encodeIfPresent(maxItems, forKey: .maxItems)
    try c.encodeIfPresent(retentionDays, forKey: .retentionDays)
  }
}

/// `"<鍵>"`（新しい行だけ・古さの上限なし）か `{"node": "<鍵>", "take"?: "new" | "all", "maxAgeHours"?: n}`。書くときは、
/// 取り方も古さの上限も省けるつながりを鍵の文字列で書く。
extension AutomationDefinition.Input: Codable {
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case nodeKey = "node", take, maxAgeHours
  }

  init(from decoder: Decoder) throws {
    if let key = try? decoder.singleValueContainer().decode(String.self) {
      self.init(nodeKey: key)
      return
    }
    try decoder.checkKeys(CodingKeys.names)
    let c = try decoder.container(keyedBy: CodingKeys.self)
    var take = AutomationTake.new
    if let raw = try c.decodeIfPresent(String.self, forKey: .take) {
      guard let value = AutomationTake(rawValue: raw) else {
        throw DecodingError.dataCorruptedError(
          forKey: .take, in: c, debugDescription: "pass new or all")
      }
      take = value
    }
    self.init(
      nodeKey: try c.decode(String.self, forKey: .nodeKey), take: take,
      maxAgeHours: try c.decodeIfPresent(Int.self, forKey: .maxAgeHours))
  }

  func encode(to encoder: Encoder) throws {
    guard take != .new || maxAgeHours != nil else {
      var c = encoder.singleValueContainer()
      try c.encode(nodeKey)
      return
    }
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(nodeKey, forKey: .nodeKey)
    if take != .new { try c.encode(take.rawValue, forKey: .take) }
    try c.encodeIfPresent(maxAgeHours, forKey: .maxAgeHours)
  }
}

/// `command`（＋`workspace`・`directory`）か `instruction`（＋`agent`〔既定 claude〕・`model`・`tools`）のちょうど一方と、
/// `timeoutMinutes`・`coverage`・`deliver`。`deliver` の省略は次のノード。外の定義のノードの欄と同じオブジェクトに並び、保存
/// （`action_defs.action`）はこの欄だけのオブジェクト。`workspace` は書けば UUID の文字列（`Workspace.id`）。知らない鍵は、
/// このオブジェクトを読む入口（外の形はノード、保存は動作の定義の列）が照らす。
extension AutomationActionDef: Codable {
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case command, workspace, directory, agent, model, tools, instruction, timeoutMinutes, coverage,
      deliver
  }

  /// 動作の定義の欄の名前。
  static var keys: Set<String> { CodingKeys.names }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    method = try Self.method(c)
    timeoutMinutes = try c.decodeIfPresent(Int.self, forKey: .timeoutMinutes)
    coverage = try Self.coverage(c)
    destination = try Self.destination(c)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch method {
    case .command(let command):
      try c.encode(command.script, forKey: .command)
      try c.encodeIfPresent(command.workspace, forKey: .workspace)
      try c.encodeIfPresent(command.directory, forKey: .directory)
    case .agent(let agent):
      try c.encode(agent.cli, forKey: .agent)
      try c.encode(agent.model, forKey: .model)
      if !agent.tools.isEmpty { try c.encode(agent.tools, forKey: .tools) }
      try c.encode(agent.instruction, forKey: .instruction)
    }
    try c.encodeIfPresent(timeoutMinutes, forKey: .timeoutMinutes)
    try c.encodeIfPresent(coverage?.rawValue, forKey: .coverage)
    try c.encodeIfPresent(destination.wireName, forKey: .deliver)
  }

  private static func method(_ c: KeyedDecodingContainer<CodingKeys>) throws -> Method {
    switch (c.contains(.command), c.contains(.instruction)) {
    case (true, false):
      if let key = [CodingKeys.agent, .model, .tools].first(where: c.contains) {
        throw DecodingError.dataCorruptedError(
          forKey: key, in: c, debugDescription: "a command node has no \(key.stringValue)")
      }
      return .command(
        AutomationNodeCommand(
          script: try c.decode(String.self, forKey: .command),
          workspace: try c.decodeWorkspace(forKey: .workspace),
          directory: try c.decodeIfPresent(String.self, forKey: .directory)))
    case (false, true):
      if let key = [CodingKeys.workspace, .directory].first(where: c.contains) {
        throw DecodingError.dataCorruptedError(
          forKey: key, in: c, debugDescription: "an agent node has no \(key.stringValue)")
      }
      return .agent(
        AutomationNodeAgent(
          cli: try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude",
          model: try c.decode(String.self, forKey: .model),
          tools: try c.decodeIfPresent([String].self, forKey: .tools) ?? [],
          instruction: try c.decode(String.self, forKey: .instruction)))
    default:
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: c.codingPath,
          debugDescription: "pass either command (a shell command) or instruction (an agent)"))
    }
  }

  /// 値は文字列で読む——知らない値を、型の名前を出さずに言うため。
  private static func coverage(_ c: KeyedDecodingContainer<CodingKeys>) throws
    -> AutomationCoverage?
  {
    guard let raw = try c.decodeIfPresent(String.self, forKey: .coverage) else { return nil }
    guard let coverage = AutomationCoverage(rawValue: raw) else {
      throw DecodingError.dataCorruptedError(
        forKey: .coverage, in: c, debugDescription: "pass currentSet or newArrivals")
    }
    return coverage
  }

  private static func destination(_ c: KeyedDecodingContainer<CodingKeys>) throws -> Destination {
    guard let raw = try c.decodeIfPresent(String.self, forKey: .deliver) else { return .nextNode }
    guard
      let destination = [Destination.taskCandidates, .report, .sideEffect].first(where: {
        $0.wireName == raw
      })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .deliver, in: c,
        debugDescription: "pass taskCandidates, report or none (leave it out to pass rows on)")
    }
    return destination
  }
}

extension AutomationActionDef.Destination {
  /// `deliver` の値。次のノードは書かない。
  var wireName: String? {
    switch self {
    case .nextNode: nil
    case .taskCandidates: "taskCandidates"
    case .report: "report"
    case .sideEffect: "none"
    }
  }
}

/// `{"kind": "interval", "minutes": 10}`・`{"kind": "cron", "expression": "0 9 * * *"}`・`{"kind": "manual"}`・
/// `{"kind": "arrival"}`。受ける鍵は種類ごとに決まる。cron 式は受けた時点で解析し、正しくなければ断る。
extension AutomationNode.Trigger: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, minutes, expression
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func only(_ keys: CodingKeys...) throws { try decoder.checkKeys(Set(keys.map(\.stringValue))) }
    switch try c.decode(String.self, forKey: .kind) {
    case "interval":
      try only(.kind, .minutes)
      self = .scheduled(.every(TimeInterval(try c.decode(Int.self, forKey: .minutes)) * 60))
    case "cron":
      try only(.kind, .expression)
      do {
        self = .scheduled(.cron(try BackgroundCron(try c.decode(String.self, forKey: .expression))))
      } catch let error as BackgroundCronError {
        throw DecodingError.dataCorruptedError(
          forKey: .expression, in: c, debugDescription: error.message)
      }
    case "manual":
      try only(.kind)
      self = .manual
    case "arrival":
      try only(.kind)
      self = .arrival
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: c, debugDescription: "pass interval, cron, manual or arrival")
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .scheduled(.every(let interval)):
      try c.encode("interval", forKey: .kind)
      try c.encode(Int(interval / 60), forKey: .minutes)
    case .scheduled(.cron(let cron)):
      try c.encode("cron", forKey: .kind)
      try c.encode(cron.expression, forKey: .expression)
    case .manual: try c.encode("manual", forKey: .kind)
    case .arrival: try c.encode("arrival", forKey: .kind)
    }
  }
}
