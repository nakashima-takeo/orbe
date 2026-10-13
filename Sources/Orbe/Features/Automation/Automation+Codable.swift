import Foundation
import OrbeSessionLog

// automations.json の JSON の形。

extension AutomationSource: Codable {
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
        AutomationSourceAgent(
          cli: try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude",
          model: try c.decodeIfPresent(String.self, forKey: .model),
          tools: try c.decode([String].self, forKey: .tools),
          request: try c.decode(String.self, forKey: .request)))
    default:
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: c.codingPath,
          debugDescription: "pass either command (a shell command) or request (an agent fetch)"))
    }
    let rawCoverage = try c.decode(String.self, forKey: .coverage)
    guard let coverage = AutomationCoverage(rawValue: rawCoverage) else {
      throw DecodingError.dataCorruptedError(
        forKey: .coverage, in: c, debugDescription: "pass newArrivals, currentSet or everything")
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
      try c.encodeIfPresent(agent.model, forKey: .model)
      try c.encode(agent.tools, forKey: .tools)
      try c.encode(agent.request, forKey: .request)
    }
  }
}

/// `command`（＋`directory`）か `instruction`（＋`agent`〔既定 claude〕・`model`）のちょうど一方。段はツールを持たないので、
/// `tools` があれば読まない。
extension AutomationStep: Codable {
  private enum CodingKeys: String, CodingKey {
    case name, command, directory, agent, model, instruction, tools
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    guard !c.contains(.tools) else {
      throw DecodingError.dataCorruptedError(
        forKey: .tools, in: c, debugDescription: "a step has no tools")
    }
    switch (c.contains(.command), c.contains(.instruction)) {
    case (true, false):
      method = .command(
        BackgroundCommand(
          script: try c.decode(String.self, forKey: .command),
          directory: try c.decodeIfPresent(String.self, forKey: .directory)))
    case (false, true):
      method = .agent(
        AutomationStepAgent(
          cli: try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude",
          model: try c.decodeIfPresent(String.self, forKey: .model),
          instruction: try c.decode(String.self, forKey: .instruction)))
    default:
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: c.codingPath,
          debugDescription: "pass either command (a shell command) or instruction (an agent step)"))
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    switch method {
    case .command(let command):
      try c.encode(command.script, forKey: .command)
      try c.encodeIfPresent(command.directory, forKey: .directory)
    case .agent(let agent):
      try c.encode(agent.cli, forKey: .agent)
      try c.encodeIfPresent(agent.model, forKey: .model)
      try c.encode(agent.instruction, forKey: .instruction)
    }
  }
}

/// `{"kind": "taskCandidates"}`・`{"kind": "command", "command", "directory"?, "timeoutMinutes"?}`・`{"kind": "report"}`。
extension AutomationSink: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, command, directory, timeoutMinutes
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .kind) {
    case "taskCandidates": self = .taskCandidates
    case "command":
      self = .command(
        AutomationSinkCommand(
          command: BackgroundCommand(
            script: try c.decode(String.self, forKey: .command),
            directory: try c.decodeIfPresent(String.self, forKey: .directory)),
          timeoutMinutes: try c.decodeIfPresent(Int.self, forKey: .timeoutMinutes)))
    case "report": self = .report
    default: throw unknownSinkKind(c, .kind)
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .taskCandidates: try c.encode("taskCandidates", forKey: .kind)
    case .command(let sink):
      try c.encode("command", forKey: .kind)
      try c.encode(sink.command.script, forKey: .command)
      try c.encodeIfPresent(sink.command.directory, forKey: .directory)
      try c.encodeIfPresent(sink.timeoutMinutes, forKey: .timeoutMinutes)
    case .report: try c.encode("report", forKey: .kind)
    }
  }
}

/// `{"kind": "taskCandidates", "proposed": …, "resolved": …, "withdrawn": …, "rejected": …}`・
/// `{"kind": "command", "commandLine": …, "ending": …, "count": …}`・`{"kind": "report", "text"?: …}`。
extension AutomationSinkReport: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, text
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .kind) {
    case "taskCandidates": self = .taskCandidates(try AutomationTaskCandidatesReport(from: decoder))
    case "command": self = .command(try AutomationCommandReport(from: decoder))
    case "report": self = .report(text: try c.decodeIfPresent(String.self, forKey: .text))
    default: throw unknownSinkKind(c, .kind)
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .taskCandidates(let report):
      try c.encode("taskCandidates", forKey: .kind)
      try report.encode(to: encoder)
    case .command(let report):
      try c.encode("command", forKey: .kind)
      try report.encode(to: encoder)
    case .report(let text):
      try c.encode("report", forKey: .kind)
      try c.encodeIfPresent(text, forKey: .text)
    }
  }
}

/// 種類は文字列で読む——知らない種類を、型の名前を出さずに言うため。
private func unknownSinkKind<Key: CodingKey>(_ c: KeyedDecodingContainer<Key>, _ key: Key)
  -> DecodingError
{
  DecodingError.dataCorruptedError(
    forKey: key, in: c, debugDescription: "pass taskCandidates, command or report")
}

/// 値は文字列で読む——知らない通知先を、型の名前を出さずに言うため。
extension AutomationNotify: Codable {
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    guard let notify = Self(rawValue: try c.decode(String.self)) else {
      throw DecodingError.dataCorruptedError(
        in: c, debugDescription: "pass menuBar or notificationCenter")
    }
    self = notify
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(rawValue)
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

extension AutomationItem: Codable {
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

extension AutomationProposal: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, automationId, item, title, due, proposedAt, state, taskId
  }

  private enum StateName: String, Codable {
    case open, accepted, dismissed, resolved
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(Int.self, forKey: .id)
    automationId = try c.decode(Int.self, forKey: .automationId)
    item = try c.decode(AutomationItem.self, forKey: .item)
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
    try c.encode(automationId, forKey: .automationId)
    try c.encode(item, forKey: .item)
    try c.encode(title, forKey: .title)
    try c.encodeIfPresent(due, forKey: .due)
    try c.encode(proposedAt, forKey: .proposedAt)
    try c.encode(state.name, forKey: .state)
    if case .accepted(let taskId) = state { try c.encode(taskId, forKey: .taskId) }
  }
}

extension AutomationProposal.State {
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
