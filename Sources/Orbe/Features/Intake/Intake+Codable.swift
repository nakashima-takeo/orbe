import Foundation
import OrbeSessionLog

// 受信の永続（intakes.json）と制御 API が共有する JSON の形。

extension IntakeFetch: Codable {
  private enum CodingKeys: String, CodingKey {
    case command, directory, agent, model, tools, request, coverage
  }

  /// `command` があればコマンド、`request` があれば agent（`agent` の既定は claude）。両方・どちらも無いは不正。
  /// `coverage` は必須。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch (c.contains(.command), c.contains(.request)) {
    case (true, false):
      method = .command(
        BackgroundCommand(
          script: try c.decode(String.self, forKey: .command),
          directory: try c.decodeIfPresent(String.self, forKey: .directory)))
    case (false, true):
      method = .agent(
        IntakeAgentFetch(
          cli: try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude",
          model: try c.decode(String.self, forKey: .model),
          tools: try c.decode([String].self, forKey: .tools),
          request: try c.decode(String.self, forKey: .request)))
    default:
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: c.codingPath,
          debugDescription: "pass either command (a shell command) or request (an agent fetch)"))
    }
    let rawCoverage = try c.decode(String.self, forKey: .coverage)
    guard let coverage = IntakeCoverage(rawValue: rawCoverage) else {
      throw DecodingError.dataCorruptedError(
        forKey: .coverage, in: c, debugDescription: "pass currentSet or newArrivals")
    }
    self.coverage = coverage
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(coverage.rawValue, forKey: .coverage)
    switch method {
    case .command(let command):
      try c.encode(command.script, forKey: .command)
      try c.encodeIfPresent(command.directory, forKey: .directory)
    case .agent(let agent):
      try c.encode(agent.cli, forKey: .agent)
      try c.encode(agent.model, forKey: .model)
      try c.encode(agent.tools, forKey: .tools)
      try c.encode(agent.request, forKey: .request)
    }
  }
}

extension IntakeJudge: Codable {
  private enum CodingKeys: String, CodingKey {
    case agent, model, instruction
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    cli = try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude"
    model = try c.decode(String.self, forKey: .model)
    instruction = try c.decode(String.self, forKey: .instruction)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(cli, forKey: .agent)
    try c.encode(model, forKey: .model)
    try c.encode(instruction, forKey: .instruction)
  }
}

/// いつの形は `{"everyMinutes": 30}` か `{"dailyAt": ["09:00", "13:00"]}`。
extension BackgroundTiming: Codable {
  private enum CodingKeys: String, CodingKey {
    case everyMinutes, dailyAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch (c.contains(.everyMinutes), c.contains(.dailyAt)) {
    case (true, false):
      self = .every(TimeInterval(try c.decode(Int.self, forKey: .everyMinutes)) * 60)
    case (false, true):
      var times = Set<BackgroundTimeOfDay>()
      for text in try c.decode([String].self, forKey: .dailyAt) {
        guard let time = BackgroundTimeOfDay(text) else {
          throw DecodingError.dataCorruptedError(
            forKey: .dailyAt, in: c, debugDescription: "not HH:MM: \(text)")
        }
        times.insert(time)
      }
      self = .daily(times)
    default:
      throw DecodingError.dataCorrupted(
        .init(codingPath: c.codingPath, debugDescription: "pass either everyMinutes or dailyAt"))
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .every(let interval):
      try c.encode(Int(interval / 60), forKey: .everyMinutes)
    case .daily(let times):
      try c.encode(
        times.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }.map(\.text), forKey: .dailyAt)
    }
  }
}

extension BackgroundTimeOfDay {
  /// `HH:MM`（2 桁ずつ）。範囲は `BackgroundTiming.validate` が見る。
  init?(_ text: String) {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCII) }),
      let hour = Int(parts[0]), let minute = Int(parts[1])
    else { return nil }
    self.init(hour: hour, minute: minute)
  }

  var text: String { String(format: "%02d:%02d", hour, minute) }
}

extension IntakeItem: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, link, body, time
  }

  /// 取得の出力 1 行の関門でもある。id は空でなく、link は http か https の URL、time は ISO 8601。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "empty id")
    }
    link = try c.decode(String.self, forKey: .link)
    guard Self.isWebLink(link) else {
      throw DecodingError.dataCorruptedError(
        forKey: .link, in: c, debugDescription: "not an http(s) URL")
    }
    body = try c.decode(String.self, forKey: .body)
    let rawTime = try c.decode(String.self, forKey: .time)
    guard let time = SessionEvent.parseISO8601(rawTime) else {
      throw DecodingError.dataCorruptedError(
        forKey: .time, in: c, debugDescription: "not ISO 8601")
    }
    self.time = time
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(link, forKey: .link)
    try c.encode(body, forKey: .body)
    try c.encode(SessionEvent.iso8601(time), forKey: .time)
  }

  private static func isWebLink(_ text: String) -> Bool {
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", url.host?.isEmpty == false
    else { return false }
    return true
  }
}

extension IntakeProposal: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, intakeId, item, title, due, proposedAt, state, taskId
  }

  private enum StateName: String, Codable {
    case open, accepted, dismissed, resolved
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(Int.self, forKey: .id)
    intakeId = try c.decode(Int.self, forKey: .intakeId)
    item = try c.decode(IntakeItem.self, forKey: .item)
    title = try c.decode(String.self, forKey: .title)
    due = try c.decodeIfPresent(TaskItem.DueDate.self, forKey: .due)
    proposedAt = try c.decode(Date.self, forKey: .proposedAt)
    switch try c.decode(StateName.self, forKey: .state) {
    case .open: state = .open
    case .accepted: state = .accepted(taskId: try c.decode(Int.self, forKey: .taskId))
    case .dismissed: state = .dismissed
    case .resolved: state = .resolved
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(intakeId, forKey: .intakeId)
    try c.encode(item, forKey: .item)
    try c.encode(title, forKey: .title)
    try c.encodeIfPresent(due, forKey: .due)
    try c.encode(proposedAt, forKey: .proposedAt)
    try c.encode(state.name, forKey: .state)
    if case .accepted(let taskId) = state { try c.encode(taskId, forKey: .taskId) }
  }
}

extension IntakeProposal.State {
  /// 永続とワイヤの語（open / accepted / dismissed / resolved）。
  var name: String {
    switch self {
    case .open: "open"
    case .accepted: "accepted"
    case .dismissed: "dismissed"
    case .resolved: "resolved"
    }
  }
}
