import Foundation

/// エージェントセッションの同一性（command + sessionId）の寿命イベント。`agent-sessions.jsonl` の
/// 1 行と同じ形で、Orbe 本体（書き手）と `orb` CLI（読み手）が共有する。
///
/// wire 形は平坦な JSON で `origin` / `reason` / `title` は closed のときだけ現れる。型では直和 `Kind` で
/// 持ち、opened に origin や title が付いた値を作れないようにする（そういう行は復号エラー＝読み飛ばし対象）。
public struct SessionEvent: Codable, Equatable {
  /// 同一性の終わり方。`agent` / `unresolved` はタブの中で決まり、残る 3 値はタブが store から
  /// 外れた経路（`TabCloseOrigin`）の写し。
  public enum CloseOrigin: String, Codable, CaseIterable {
    case agent, gesture, process, controlAPI, unresolved
  }

  public enum Kind: Equatable {
    case opened
    /// `title` は閉じた時点のタブの表示タイトル（タブバーに出ていたもの）。同一性の属性ではなく閉じた
    /// 時点のスナップショットで、途中の変化は追わない。空なら nil。
    case closed(origin: CloseOrigin, reason: String?, title: String?)
  }

  public struct Workspace: Codable, Equatable {
    public var name: String
    public var rootPath: String

    public init(name: String, rootPath: String) {
      self.name = name
      self.rootPath = rootPath
    }
  }

  public struct Agent: Codable, Equatable {
    public var command: String
    public var sessionId: String

    public init(command: String, sessionId: String) {
      self.command = command
      self.sessionId = sessionId
    }
  }

  public var ts: Date
  public var kind: Kind
  public var workspace: Workspace
  public var cwd: String
  public var agent: Agent

  /// `ts` は wire の精度（ミリ秒）に丸め、closed の空の `reason` / `title` は nil に正規化して持つ——
  /// 書いた値と読み戻した値が等しいことを型の構築で保証する。
  public init(ts: Date, kind: Kind, workspace: Workspace, cwd: String, agent: Agent) {
    self.ts = Self.parseISO8601(Self.iso8601(ts)) ?? ts
    self.kind = Self.normalized(kind)
    self.workspace = workspace
    self.cwd = cwd
    self.agent = agent
  }

  public var sessionId: String { agent.sessionId }

  /// closed のときだけ非 nil。
  public var closeOrigin: CloseOrigin? {
    if case .closed(let origin, _, _) = kind { return origin }
    return nil
  }

  /// closed の `reason`（無ければ nil）。
  public var closeReason: String? {
    if case .closed(_, let reason, _) = kind { return reason }
    return nil
  }

  /// closed の閉じた時点のタブタイトル（無ければ nil）。
  public var closeTitle: String? {
    if case .closed(_, _, let title) = kind { return title }
    return nil
  }

  private static func normalized(_ kind: Kind) -> Kind {
    guard case .closed(let origin, let reason, let title) = kind else { return kind }
    return .closed(origin: origin, reason: nonEmpty(reason), title: nonEmpty(title))
  }

  private static func nonEmpty(_ s: String?) -> String? {
    s.flatMap { $0.isEmpty ? nil : $0 }
  }

  // MARK: - wire 形

  private enum CodingKeys: String, CodingKey {
    case ts, event, workspace, cwd, agent, origin, reason, title
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try c.decode(String.self, forKey: .ts)
    guard let ts = Self.parseISO8601(raw) else {
      throw DecodingError.dataCorruptedError(
        forKey: .ts, in: c, debugDescription: "not ISO 8601: \(raw)")
    }
    self.ts = ts
    workspace = try c.decode(Workspace.self, forKey: .workspace)
    cwd = try c.decode(String.self, forKey: .cwd)
    agent = try c.decode(Agent.self, forKey: .agent)
    switch try c.decode(String.self, forKey: .event) {
    case "opened":
      guard !c.contains(.origin), !c.contains(.reason), !c.contains(.title) else {
        throw DecodingError.dataCorruptedError(
          forKey: .event, in: c, debugDescription: "opened carries origin/reason/title")
      }
      kind = .opened
    case "closed":
      kind = Self.normalized(
        .closed(
          origin: try c.decode(CloseOrigin.self, forKey: .origin),
          reason: try c.decodeIfPresent(String.self, forKey: .reason),
          title: try c.decodeIfPresent(String.self, forKey: .title)))
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .event, in: c, debugDescription: "unknown event: \(other)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(Self.iso8601(ts), forKey: .ts)
    try c.encode(workspace, forKey: .workspace)
    try c.encode(cwd, forKey: .cwd)
    try c.encode(agent, forKey: .agent)
    switch kind {
    case .opened:
      try c.encode("opened", forKey: .event)
    case .closed(let origin, let reason, let title):
      try c.encode("closed", forKey: .event)
      try c.encode(origin, forKey: .origin)
      try c.encodeIfPresent(reason, forKey: .reason)
      try c.encodeIfPresent(title, forKey: .title)
    }
  }

  // MARK: - 時刻（UTC ISO 8601・ミリ秒・Z）

  private static let fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
  }()

  private static let whole: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
  }()

  /// wire の時刻文字列（`2026-09-06T10:32:37.123Z`）。CLI の相対時刻の解決・群の `at` もこれで書く。
  public static func iso8601(_ date: Date) -> String {
    fractional.string(from: date)
  }

  /// 小数秒あり・なしの両方を受理する。解けなければ nil。
  public static func parseISO8601(_ s: String) -> Date? {
    fractional.date(from: s) ?? whole.date(from: s)
  }
}
