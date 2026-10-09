import Foundation
import OrbeSessionLog

/// 受信 1 つ。定義（名前・取得・判定・いつ）と、回を重ねて溜まるもの（前回の取得結果・回の記録）を持つ。
/// 不変条件（ID の一意・定義が正しい）は `IntakeStore` が保証する。
struct Intake: Equatable, Identifiable {
  /// 永続の短い整数。使い回さない。
  let id: Int
  var definition: IntakeDefinition
  /// 止めているのは予定だけ（「今すぐ」は受ける）。
  var paused: Bool
  let createdAt: Date
  /// 最後に成功した回で取れた項目。新しい項目・提案の下げ・重なりは、すべてこの集合で言う。
  var lastFetched: [IntakeSeen]
  /// 次の回は、取れた全件を新しい項目とみなす（取得か判定を書き換えた直後）。
  var reviewAll: Bool
  var lastRunAt: Date?
  /// 新しい順。
  var runs: [IntakeRun]

  static let retainedRuns = 20

  /// 番人の数え始め。
  var anchor: Date { lastRunAt ?? createdAt }
}

extension Intake: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, definition, paused, createdAt, lastFetched, reviewAll, lastRunAt, runs
  }

  /// 定義以外は、欠けていれば無いものとして読む。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(Int.self, forKey: .id)
    definition = try c.decode(IntakeDefinition.self, forKey: .definition)
    paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    lastFetched = try c.decodeIfPresent([IntakeSeen].self, forKey: .lastFetched) ?? []
    reviewAll = try c.decodeIfPresent(Bool.self, forKey: .reviewAll) ?? false
    lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
    runs = try c.decodeIfPresent([IntakeRun].self, forKey: .runs) ?? []
  }
}

/// 受信の定義。制御 API・MCP・`orb intake set`・intakes.json が同じ形で読み書きする。
struct IntakeDefinition: Equatable {
  var name: String
  var fetch: IntakeFetch
  var judge: IntakeJudge
  var when: BackgroundTiming
}

/// 何を取るか。コマンドは 1 行 1 項目の JSON を自分で出し、agent は渡したツールだけで依頼文どおりに取る。
enum IntakeFetch: Equatable {
  case command(BackgroundCommand)
  case agent(IntakeAgentFetch)
}

struct IntakeAgentFetch: Equatable {
  var cli: String
  var model: String
  var tools: [String]
  var request: String
}

/// 新しい項目を読んでタスクにすべきものを提案する役。ツールを持たない閉じた形でだけ走る。
struct IntakeJudge: Equatable {
  var cli: String
  var model: String
  var instruction: String
}

/// 取得の出力 1 行。`id` は受信の中での同一性、`link` は受信をまたぐ同一性。
struct IntakeItem: Equatable {
  let id: String
  let link: String
  let body: String
  let time: Date
}

/// 前回の取得結果に覚えておく 1 項目。
struct IntakeSeen: Codable, Equatable {
  let id: String
  let link: String
}

/// 判定が出した提案。リンクは全提案を通じて一意。
struct IntakeProposal: Equatable, Identifiable {
  let id: Int
  /// 提案した受信（履歴。棚に出す受信は `IntakeStore.shelf(of:)` が導く）。
  let intakeId: Int
  let item: IntakeItem
  let title: String
  let due: TaskItem.DueDate?
  let proposedAt: Date
  var state: State

  enum State: Equatable {
    case open
    case accepted(taskId: Int)
    case dismissed
    /// 判定が対応済みとした。
    case resolved
  }
}

/// 1 回の記録。
struct IntakeRun: Codable, Equatable {
  enum Trigger: String, Codable {
    case schedule
    case now
  }

  var startedAt: Date
  var endedAt: Date
  var trigger: Trigger
  var fetch: IntakeFetchReport
  /// 判定に回した項目の数。
  var newItems: Int
  /// 判定を起こさなかった回は nil。
  var judge: IntakeJudgeReport?
  /// この回の確定で下げた（出ていた）提案の数。
  var withdrawn: Int
  /// 失敗した回の理由。失敗した回は取得済みも提案も動かさない。
  var failure: String?
}

/// 取得の段の記録。
struct IntakeFetchReport: Codable, Equatable {
  var commandLine: String
  var ending: String
  /// 取れた項目の数。
  var items: Int
  var rejected: IntakeRejections
}

/// 判定の段の記録。
struct IntakeJudgeReport: Codable, Equatable {
  var commandLine: String
  var ending: String
  /// 受けた提案の数。
  var proposed: Int
  /// 対応済みにした提案の数。
  var resolved: Int
  var rejected: IntakeRejections
}

/// 捨てた行。理由は最初の数件だけ残す。
struct IntakeRejections: Codable, Equatable {
  var count = 0
  var reasons: [String] = []

  static let retainedReasons = 5

  mutating func add(_ reason: String) {
    count += 1
    if reasons.count < Self.retainedReasons { reasons.append(reason) }
  }
}

enum IntakeError: Error, Equatable {
  case intakeNotFound(Int)
  case proposalNotFound(Int)
  /// 値か組み合わせが不変条件に反する。
  case invalid(String)
  /// 走っている回がある。
  case running(Int)
}

// MARK: - 永続とワイヤの形

extension IntakeDefinition: Codable {
  private enum CodingKeys: String, CodingKey {
    case name, fetch, judge, when
  }
}

extension IntakeFetch: Codable {
  private enum CodingKeys: String, CodingKey {
    case command, directory, agent, model, tools, request
  }

  /// `command` があればコマンド、`request` があれば agent（`agent` の既定は claude）。両方・どちらも無いは不正。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch (c.contains(.command), c.contains(.request)) {
    case (true, false):
      self = .command(
        BackgroundCommand(
          script: try c.decode(String.self, forKey: .command),
          directory: try c.decodeIfPresent(String.self, forKey: .directory)))
    case (false, true):
      self = .agent(
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
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
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
