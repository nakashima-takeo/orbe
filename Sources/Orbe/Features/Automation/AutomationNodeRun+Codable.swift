import Foundation

// 部品の 1 回の記録の JSON（外の形と保存の形）。

extension AutomationNodeRun: Encodable {
  private enum CodingKeys: String, CodingKey {
    case startedAt, endedAt, trigger, taken, dropped, execution, breach, result, withdrawn, failed
  }

  /// 外の形。無い値は書かない。`dropped` は 0 でない理由だけ。
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(startedAt, forKey: .startedAt)
    try c.encode(endedAt, forKey: .endedAt)
    try c.encode(trigger, forKey: .trigger)
    try c.encodeIfPresent(taken, forKey: .taken)
    if !dropped.isEmpty { try c.encode(dropped, forKey: .dropped) }
    try c.encode(execution, forKey: .execution)
    try c.encodeIfPresent(breach, forKey: .breach)
    try c.encodeIfPresent(result, forKey: .result)
    try c.encodeIfPresent(withdrawn, forKey: .withdrawn)
    try c.encodeIfPresent(failure, forKey: .failed)
  }
}

/// 回の記録の保存の JSON（`runs.record`）。列（時刻・契機・失敗）と、回の履歴から数えられる数（取った数・読んで捨てた数）は
/// 持たず、入力を読む回か（`reads`。取った数を出すか）・持ち越した捨てた数と読む前に期限で消えた数（`carried`）・実行・
/// 外したこと・結果・下げた数だけを持つ。
struct AutomationRunStore: Codable {
  /// 入力を読む部品の回か（取った行が 0 件の回も）。
  var reads: Bool
  var carried: AutomationDrops
  var execution: AutomationNodePass.Execution
  var breach: AutomationRejections?
  var result: AutomationNodeRun.Result?
  var withdrawn: Int?

  private enum CodingKeys: String, CodingKey {
    case reads, carried, execution, breach, result, withdrawn
  }

  init(_ run: AutomationNodeRun, carried: AutomationDrops) {
    reads = run.taken != nil
    self.carried = carried
    execution = run.execution
    breach = run.breach
    result = run.result
    withdrawn = run.withdrawn
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    reads = try c.decodeIfPresent(Bool.self, forKey: .reads) ?? false
    carried = try c.decodeIfPresent(AutomationDrops.self, forKey: .carried) ?? AutomationDrops()
    execution = try c.decode(AutomationNodePass.Execution.self, forKey: .execution)
    breach = try c.decodeIfPresent(AutomationRejections.self, forKey: .breach)
    result = try c.decodeIfPresent(AutomationNodeRun.Result.self, forKey: .result)
    withdrawn = try c.decodeIfPresent(Int.self, forKey: .withdrawn)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if reads { try c.encode(reads, forKey: .reads) }
    if !carried.isEmpty { try c.encode(carried, forKey: .carried) }
    try c.encode(execution, forKey: .execution)
    try c.encodeIfPresent(breach, forKey: .breach)
    try c.encodeIfPresent(result, forKey: .result)
    try c.encodeIfPresent(withdrawn, forKey: .withdrawn)
  }
}

/// `{"kind": "fetch", "fresh", "duplicates"?}`・`{"kind": "process", "fresh", "duplicates"?}`・
/// `{"kind": "judge", "proposed", "resolved", "dismissed"?}`・`{"kind": "report", "text"?}`・
/// `{"kind": "sideEffect", "count"}`・`{"kind": "work", "text"?, "nothing"?}`。
extension AutomationNodeRun.Result: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, fresh, duplicates, proposed, resolved, dismissed, text, count, nothing
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .kind) {
    case "fetch":
      self = .fetch(
        fresh: try c.decode(Int.self, forKey: .fresh),
        duplicates: try c.decodeIfPresent(Int.self, forKey: .duplicates) ?? 0)
    case "process":
      self = .process(
        fresh: try c.decode(Int.self, forKey: .fresh),
        duplicates: try c.decodeIfPresent(Int.self, forKey: .duplicates) ?? 0)
    case "judge":
      self = .judge(
        proposed: try c.decode(Int.self, forKey: .proposed),
        resolved: try c.decode(Int.self, forKey: .resolved),
        dismissed: try c.decodeIfPresent([AutomationDismissal].self, forKey: .dismissed) ?? [])
    case "report": self = .report(text: try c.decodeIfPresent(String.self, forKey: .text))
    case "sideEffect": self = .sideEffect(count: try c.decode(Int.self, forKey: .count))
    case "work":
      self = .work(
        text: try c.decodeIfPresent(String.self, forKey: .text),
        nothing: try c.decodeIfPresent(String.self, forKey: .nothing))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: c, debugDescription: "unknown result kind")
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .fetch(let fresh, let duplicates):
      try c.encode("fetch", forKey: .kind)
      try c.encode(fresh, forKey: .fresh)
      if duplicates > 0 { try c.encode(duplicates, forKey: .duplicates) }
    case .process(let fresh, let duplicates):
      try c.encode("process", forKey: .kind)
      try c.encode(fresh, forKey: .fresh)
      if duplicates > 0 { try c.encode(duplicates, forKey: .duplicates) }
    case .judge(let proposed, let resolved, let dismissed):
      try c.encode("judge", forKey: .kind)
      try c.encode(proposed, forKey: .proposed)
      try c.encode(resolved, forKey: .resolved)
      if !dismissed.isEmpty { try c.encode(dismissed, forKey: .dismissed) }
    case .report(let text):
      try c.encode("report", forKey: .kind)
      try c.encodeIfPresent(text, forKey: .text)
    case .sideEffect(let count):
      try c.encode("sideEffect", forKey: .kind)
      try c.encode(count, forKey: .count)
    case .work(let text, let nothing):
      try c.encode("work", forKey: .kind)
      try c.encodeIfPresent(text, forKey: .text)
      try c.encodeIfPresent(nothing, forKey: .nothing)
    }
  }
}

/// 理由ごとの数の object（0 の理由は書かない）。知らない理由は使えない記録として断る。
extension AutomationDrops: Codable {
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    for (raw, count) in try c.decode([String: Int].self) {
      guard let reason = Reason(rawValue: raw), count >= 0 else {
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown drop \(raw)")
      }
      add(reason, count)
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }))
  }
}
