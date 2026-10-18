import Foundation

/// 部品の 1 回の記録。確定（失敗の記録を含む）が、取る・積む・当て直すときに決まった数と部品の 1 回の結果から組む。保存の形は
/// 種類だけを持ち、外の形（`list_automations` の `runs`）は保存の形に英文を足したもの（`AutomationRunWire`）。手段を起こさなかった
/// 契機（取る行が 0 件）は記録しないので、いつも実行の記録を持つ。
struct AutomationPartRun: Equatable {
  enum Trigger: String, Codable {
    case schedule
    case now
    /// 入力の行が届いた（「届いたら」の部品の回）。
    case arrival
  }

  var startedAt: Date
  var endedAt: Date
  var trigger: Trigger
  /// 溜まりから取った行の数。入力の無い部品は持たない。
  var taken: Int?
  /// 取る時点で捨てた数と、部品の状態に溜まっていた捨てた数の和。
  var dropped = AutomationDrops()
  /// 使った出力を出した呼び出しの記録（出し直したなら出し直し。失敗した回は最後の呼び出し）。
  var execution: AutomationPartPass.Execution
  /// 出力が決まりを外した回だけ持つ。
  var breach: Breach?
  /// 役割ごとの結果。失敗した回は持たない。
  var result: Result?
  /// 下流の溜まりへ積んだ行の数。行き先が次の部品の成功した回だけ持つ。
  var stacked: Int?
  /// この回の確定で下げた（判断待ちだった）候補の数。取得の成功した回だけ持つ。
  var withdrawn: Int?
  var failure: AutomationFailure?

  /// 決まりを外したこと。外れた行は件数と最初の数件だけを残す。
  struct Breach: Equatable, Codable {
    /// 1 回目の出力の外れた行。
    let lines: AutomationRejections
    /// 出し直したときだけある。
    let redo: Redo?
  }

  struct Redo: Equatable {
    /// 1 回目の呼び出しの記録。
    let firstCall: AutomationPartPass.Execution
    /// 出し直しでもまだ外れていた行。
    let lines: AutomationRejections
  }

  enum Result: Equatable {
    /// `fresh` は下流へ渡す行の数（前回の出力に無かった項目）。
    case fetch(fresh: Int)
    case process
    /// `dismissed` は確定の当て直しで捨てた案。
    case judge(proposed: Int, resolved: Int, dismissed: [AutomationDismissal])
    /// 言うことが無かった回は nil。
    case report(text: String?)
    /// 標準入力に渡した行の数。
    case sideEffect(count: Int)
    /// 何もしなかった回は `nothing` に理由を持つ。
    case work(text: String?, nothing: String?)
  }

  var failed: Bool { failure != nil }
}

extension AutomationPartRun.Breach {
  init(_ breach: AutomationPartPass.Breach) {
    self.init(
      lines: AutomationRejections(breach.lines),
      redo: breach.redo.map {
        AutomationPartRun.Redo(firstCall: $0.firstCall, lines: AutomationRejections($0.lines))
      })
  }
}

/// 捨てた行の数（理由ごと）。
struct AutomationDrops: Equatable {
  private(set) var counts: [Reason: Int] = [:]

  enum Reason: String, CaseIterable {
    /// 今の集合の取得の部品から来て、その項目がもう前回の出力に無い。
    case leftCurrentSet
    /// 届いてから古さの上限を過ぎた。
    case expired
    /// 出どころのリンクに候補がある。
    case proposed
    /// 同じリンクの、より新しい行がある。
    case sameLink
    /// 積む時点で件数の上限を超えた。
    case overflow
    /// 判定の部品へ、出どころ（元になった取得の項目）の無いまま届いた・溜まっていた。
    case unsourced

    init(_ reason: AutomationInbox.Reason) {
      switch reason {
      case .unsourced: self = .unsourced
      case .leftCurrentSet: self = .leftCurrentSet
      case .expired: self = .expired
      case .proposed: self = .proposed
      case .sameLink: self = .sameLink
      }
    }
  }

  var isEmpty: Bool { counts.isEmpty }

  var total: Int { counts.values.reduce(0, +) }

  mutating func add(_ reason: Reason, _ count: Int = 1) {
    guard count > 0 else { return }
    counts[reason, default: 0] += count
  }

  mutating func add(_ other: AutomationDrops) {
    for (reason, count) in other.counts { add(reason, count) }
  }
}

/// 出力が決まりを外した最初の回の印（部品ごと）。
struct AutomationBreachMark: Equatable, Codable {
  /// その回の開始時刻。
  let at: Date
  let lines: AutomationRejections
  /// 出し直したか。
  let redone: Bool
  /// 回が通ったか（出し直しで通った回だけが当たる）。
  let passed: Bool
}

/// 外れた行。件数と、最初の数件の行だけを残す。
struct AutomationRejections: Codable, Equatable {
  var count = 0
  var lines: [AutomationBrokenLine] = []

  static let retainedLines = 5

  init(count: Int = 0, lines: [AutomationBrokenLine] = []) {
    self.count = count
    self.lines = lines
  }

  init(_ lines: [AutomationBrokenLine]) {
    self.init(count: lines.count, lines: Array(lines.prefix(Self.retainedLines)))
  }
}

// MARK: - JSON

extension AutomationPartRun: Codable {
  private enum CodingKeys: String, CodingKey {
    case startedAt, endedAt, trigger, taken, dropped, execution, breach, result, stacked, withdrawn
    case failed
  }

  /// 無い値は書かない。`dropped` は 0 でない理由だけ。
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
    try c.encodeIfPresent(stacked, forKey: .stacked)
    try c.encodeIfPresent(withdrawn, forKey: .withdrawn)
    try c.encodeIfPresent(failure, forKey: .failed)
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    startedAt = try c.decode(Date.self, forKey: .startedAt)
    endedAt = try c.decode(Date.self, forKey: .endedAt)
    trigger = try c.decode(Trigger.self, forKey: .trigger)
    taken = try c.decodeIfPresent(Int.self, forKey: .taken)
    dropped = try c.decodeIfPresent(AutomationDrops.self, forKey: .dropped) ?? AutomationDrops()
    execution = try c.decode(AutomationPartPass.Execution.self, forKey: .execution)
    breach = try c.decodeIfPresent(Breach.self, forKey: .breach)
    result = try c.decodeIfPresent(Result.self, forKey: .result)
    stacked = try c.decodeIfPresent(Int.self, forKey: .stacked)
    withdrawn = try c.decodeIfPresent(Int.self, forKey: .withdrawn)
    failure = try c.decodeIfPresent(AutomationFailure.self, forKey: .failed)
  }
}

/// `{"firstCall": …, "lines"?: …}`。`lines` は出し直しでもまだ外れていたときだけ書く。
extension AutomationPartRun.Redo: Codable {
  private enum CodingKeys: String, CodingKey {
    case firstCall, lines
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      firstCall: try c.decode(AutomationPartPass.Execution.self, forKey: .firstCall),
      lines: try c.decodeIfPresent(AutomationRejections.self, forKey: .lines)
        ?? AutomationRejections())
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(firstCall, forKey: .firstCall)
    if lines.count > 0 { try c.encode(lines, forKey: .lines) }
  }
}

/// `{"kind": "fetch", "fresh"}`・`{"kind": "process"}`・`{"kind": "judge", "proposed", "resolved", "dismissed"?}`・
/// `{"kind": "report", "text"?}`・`{"kind": "sideEffect", "count"}`・`{"kind": "work", "text"?, "nothing"?}`。
extension AutomationPartRun.Result: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, fresh, proposed, resolved, dismissed, text, count, nothing
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .kind) {
    case "fetch": self = .fetch(fresh: try c.decode(Int.self, forKey: .fresh))
    case "process": self = .process
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
    case .fetch(let fresh):
      try c.encode("fetch", forKey: .kind)
      try c.encode(fresh, forKey: .fresh)
    case .process:
      try c.encode("process", forKey: .kind)
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
