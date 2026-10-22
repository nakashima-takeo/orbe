import Foundation

/// 部品の 1 回の記録の中身。確定（失敗の記録を含む）が、読む・確定する・当て直すときに決まった数と部品の 1 回の結果から組む。
/// 保存は時刻・契機・失敗を列に、回の履歴から数えられない残りを JSON に持ち（`AutomationRunStore`）、外の形は保存の形に英文を
/// 足したもの（`AutomationRunWire`）。手段を起こさなかった契機（取る行が 0 件）は記録しないので、いつも実行の記録を持つ。
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
  /// 取った行の数。入力の無い部品は持たない。
  var taken: Int?
  /// 読む時点で捨てた数・読む前に期限で消えた数と、部品の持ち越しの和。
  var dropped = AutomationDrops()
  /// 使った出力を出した呼び出しの記録（出し直したなら出し直し。失敗した回は最後の呼び出し）。
  var execution: AutomationPartPass.Execution
  /// 出力が決まりを外した回だけ持つ。
  var breach: Breach?
  /// 役割ごとの結果。失敗した回は持たない。
  var result: Result?
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
    /// `fresh` は新しく有効にした行の数、`duplicates` は出来事の流れで残す期間の内に同じ id を出したので足さなかった数。
    case fetch(fresh: Int, duplicates: Int)
    case process(fresh: Int, duplicates: Int)
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
    /// 古さの上限を過ぎた。
    case expired
    /// 出どころのリンクに候補がある。
    case proposed
    /// 同じリンクの、より新しい行がある。
    case sameLink
    /// 件数の上限を超えた。
    case overflow
    /// 判定の部品へ、出どころ（元になった取得の行）の無い行が届いた。
    case unsourced
    /// 同じ回の中で、同じ id の新しい行に置き換わった。
    case replaced
    /// 受け手が読む前に、残す期間を過ぎて消えた出来事。
    case lapsed

    init(_ reason: AutomationInbox.Reason) {
      switch reason {
      case .unsourced: self = .unsourced
      case .expired: self = .expired
      case .proposed: self = .proposed
      case .sameLink: self = .sameLink
      case .overflow: self = .overflow
      case .replaced: self = .replaced
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

  /// `other` を差し引いたもの（0 以下の理由は落とす）。
  func subtracting(_ other: AutomationDrops) -> AutomationDrops {
    var rest = AutomationDrops()
    for (reason, count) in counts { rest.add(reason, count - (other.counts[reason] ?? 0)) }
    return rest
  }
}

/// 出力が決まりを外した最初の回の印（部品ごと）。印の回の記録から導く。
struct AutomationBreachMark: Equatable, Codable {
  /// その回の開始時刻。
  let at: Date
  let lines: AutomationRejections
  /// 出し直したか。
  let redone: Bool
  /// 回が通ったか（出し直しで通った回だけが当たる）。
  let passed: Bool
}

extension AutomationBreachMark {
  /// 印の回の記録から。読めない記録なら、時刻と通ったかだけを持つ。
  init(_ record: AutomationRunRecord) {
    let breach = record.run?.breach
    self.init(
      at: record.startedAt, lines: breach?.lines ?? AutomationRejections(),
      redone: breach?.redo != nil, passed: !record.failed)
  }
}

/// 回の記録 1 件。時刻・契機・成否は列から分かり、中身は読めなければ不明な記録になる。
struct AutomationRunRecord: Equatable {
  /// 記録の ID（`recordId`）。
  let id: Int
  /// 回が動いた定義。
  let defId: AutomationDefID
  let content: Content

  enum Content: Equatable {
    case known(AutomationPartRun)
    case unknown(AutomationUnknownRun)
  }

  /// 読めた中身。不明な記録は nil。
  var run: AutomationPartRun? {
    if case .known(let run) = content { run } else { nil }
  }

  var startedAt: Date {
    switch content {
    case .known(let run): run.startedAt
    case .unknown(let run): run.startedAt
    }
  }

  var endedAt: Date {
    switch content {
    case .known(let run): run.endedAt
    case .unknown(let run): run.endedAt
    }
  }

  var trigger: AutomationPartRun.Trigger {
    switch content {
    case .known(let run): run.trigger
    case .unknown(let run): run.trigger
    }
  }

  var failed: Bool {
    switch content {
    case .known(let run): run.failed
    case .unknown(let run): run.failed
    }
  }
}

/// 中身の JSON を読めない回の記録（列から分かる分だけ）。
struct AutomationUnknownRun: Equatable {
  let startedAt: Date
  let endedAt: Date
  let trigger: AutomationPartRun.Trigger
  let failed: Bool
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

extension AutomationPartRun: Encodable {
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
/// 持たず、持ち越した捨てた数と読む前に期限で消えた数（`carried`）・実行・外したこと・結果・下げた数だけを持つ。
struct AutomationRunStore: Codable {
  var carried: AutomationDrops
  var execution: AutomationPartPass.Execution
  var breach: AutomationPartRun.Breach?
  var result: AutomationPartRun.Result?
  var withdrawn: Int?

  private enum CodingKeys: String, CodingKey {
    case carried, execution, breach, result, withdrawn
  }

  init(_ run: AutomationPartRun, carried: AutomationDrops) {
    self.carried = carried
    execution = run.execution
    breach = run.breach
    result = run.result
    withdrawn = run.withdrawn
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    carried = try c.decodeIfPresent(AutomationDrops.self, forKey: .carried) ?? AutomationDrops()
    execution = try c.decode(AutomationPartPass.Execution.self, forKey: .execution)
    breach = try c.decodeIfPresent(AutomationPartRun.Breach.self, forKey: .breach)
    result = try c.decodeIfPresent(AutomationPartRun.Result.self, forKey: .result)
    withdrawn = try c.decodeIfPresent(Int.self, forKey: .withdrawn)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if !carried.isEmpty { try c.encode(carried, forKey: .carried) }
    try c.encode(execution, forKey: .execution)
    try c.encodeIfPresent(breach, forKey: .breach)
    try c.encodeIfPresent(result, forKey: .result)
    try c.encodeIfPresent(withdrawn, forKey: .withdrawn)
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

/// `{"kind": "fetch", "fresh", "duplicates"?}`・`{"kind": "process", "fresh", "duplicates"?}`・
/// `{"kind": "judge", "proposed", "resolved", "dismissed"?}`・`{"kind": "report", "text"?}`・
/// `{"kind": "sideEffect", "count"}`・`{"kind": "work", "text"?, "nothing"?}`。
extension AutomationPartRun.Result: Codable {
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
