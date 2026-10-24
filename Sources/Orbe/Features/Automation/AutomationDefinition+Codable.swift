import Foundation

// 定義の JSON の形。読むときに断るのは形の誤りだけで、値と組み合わせは `AutomationGraph` が検証する。

/// 部品の欄と動作の定義の欄を 1 つのオブジェクトに並べる。`from` と agent の `tools` の空の配列は書かないのと同じ。
extension AutomationDefinition.Node: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, key, name, trigger, from, maxItems
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(Int.self, forKey: .id).map(AutomationNodeID.init)
    key = try c.decode(String.self, forKey: .key)
    name = try c.decode(String.self, forKey: .name)
    trigger = try c.decode(AutomationNode.Trigger.self, forKey: .trigger)
    from = try c.decodeIfPresent([AutomationDefinition.Input].self, forKey: .from) ?? []
    action = try AutomationActionDef(from: decoder)
    maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems)
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
  }
}

/// `"<鍵>"`（新しい行だけ・古さの上限なし）か `{"part": "<鍵>", "take"?: "new" | "all", "maxAgeHours"?: n}`。書くときは、
/// 取り方も古さの上限も省けるつながりを鍵の文字列で書く。
extension AutomationDefinition.Input: Codable {
  private enum CodingKeys: String, CodingKey {
    case part, take, maxAgeHours
  }

  init(from decoder: Decoder) throws {
    if let key = try? decoder.singleValueContainer().decode(String.self) {
      self.init(part: key)
      return
    }
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
      part: try c.decode(String.self, forKey: .part), take: take,
      maxAgeHours: try c.decodeIfPresent(Int.self, forKey: .maxAgeHours))
  }

  func encode(to encoder: Encoder) throws {
    guard take != .new || maxAgeHours != nil else {
      var c = encoder.singleValueContainer()
      try c.encode(part)
      return
    }
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(part, forKey: .part)
    if take != .new { try c.encode(take.rawValue, forKey: .take) }
    try c.encodeIfPresent(maxAgeHours, forKey: .maxAgeHours)
  }
}

/// `command`（＋`directory`）か `instruction`（＋`agent`〔既定 claude〕・`model`・`tools`）のちょうど一方と、`timeoutMinutes`・
/// `coverage`・`deliver`。`deliver` の省略は次の部品。外の定義の部品の欄と同じオブジェクトに並び、保存（`action_defs.action`）は
/// この欄だけのオブジェクト。
extension AutomationActionDef: Codable {
  private enum CodingKeys: String, CodingKey {
    case command, directory, agent, model, tools, instruction, timeoutMinutes, coverage, deliver
  }

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
      try c.encodeIfPresent(command.directory, forKey: .directory)
    case .agent(let agent):
      try c.encode(agent.cli, forKey: .agent)
      try c.encodeIfPresent(agent.model, forKey: .model)
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
          forKey: key, in: c, debugDescription: "a command part has no \(key.stringValue)")
      }
      return .command(
        BackgroundCommand(
          script: try c.decode(String.self, forKey: .command),
          directory: try c.decodeIfPresent(String.self, forKey: .directory)))
    case (false, true):
      guard !c.contains(.directory) else {
        throw DecodingError.dataCorruptedError(
          forKey: .directory, in: c, debugDescription: "an agent part has no directory")
      }
      return .agent(
        AutomationNodeAgent(
          cli: try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude",
          model: try c.decodeIfPresent(String.self, forKey: .model),
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
    guard let raw = try c.decodeIfPresent(String.self, forKey: .deliver) else { return .nextPart }
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
  /// `deliver` の値。次の部品は書かない。
  var wireName: String? {
    switch self {
    case .nextPart: nil
    case .taskCandidates: "taskCandidates"
    case .report: "report"
    case .sideEffect: "none"
    }
  }
}

/// `{"kind": "interval", "minutes": 10}`・`{"kind": "cron", "expression": "0 9 * * *"}`・`{"kind": "manual"}`・
/// `{"kind": "arrival"}`。cron 式は受けた時点で解析し、正しくなければ断る。
extension AutomationNode.Trigger: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, minutes, expression
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .kind) {
    case "interval":
      self = .scheduled(.every(TimeInterval(try c.decode(Int.self, forKey: .minutes)) * 60))
    case "cron":
      do {
        self = .scheduled(.cron(try BackgroundCron(try c.decode(String.self, forKey: .expression))))
      } catch let error as BackgroundCronError {
        throw DecodingError.dataCorruptedError(
          forKey: .expression, in: c, debugDescription: error.message)
      }
    case "manual": self = .manual
    case "arrival": self = .arrival
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
