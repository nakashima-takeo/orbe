import Foundation

/// 待ちの解ける条件。AI が丸ごと付け替える 1 つの値で、確認の経過（回数と実行の記録）も一緒に持つ。保つのは `TaskStore`。
struct WaitCondition: Codable, Equatable {
  /// 付けるたびにストアが振る。番人の結果がどの条件のものかを見分ける（付け直した後に古い結果を混ぜない）。
  let id: UUID
  let description: String
  let command: String
  let intervalMinutes: Int
  let deadline: Date
  /// 確認のコマンドが走る場所（絶対パス）。nil はホーム。
  let directory: String?
  /// 条件を付けた agent の会話。
  let conversation: WaitConversation?
  let setAt: Date
  /// 確認の回数（実行の記録は直近だけを残すので、別に数える）。
  var checks: Int
  /// 直近の実行の記録（古い順）。
  var log: [WaitCheck]

  /// 実行の記録に残す件数。
  static let logLimit = 20

  private enum CodingKeys: String, CodingKey {
    case id, description, command, intervalMinutes, deadline, directory, setAt, checks, log
    case conversation = "agent"
  }

  init(_ request: WaitConditionRequest, setAt: Date) {
    id = UUID()
    description = request.description
    command = request.command
    intervalMinutes = request.intervalMinutes
    deadline = request.deadline
    directory = request.directory
    conversation = request.conversation
    self.setAt = setAt
    checks = 0
    log = []
  }

  /// 番人へ渡す予定。値の検証（間隔の下限・空のコマンド・相対の作業ディレクトリ）も u1 の予定の検証に任せる。
  var schedule: BackgroundSchedule {
    BackgroundSchedule(
      job: .command(BackgroundCommand(script: command, directory: directory)),
      timing: .every(TimeInterval(intervalMinutes) * 60), deadline: deadline)
  }

  /// 番人の数え始め（最後の確認の始まり、まだなら付けた日時）。保存はしない。
  var anchor: Date { log.last?.startedAt ?? setAt }

  /// 次に確かめる時刻。期限が先に来るなら nil。
  func nextCheck(now: Date, calendar: Calendar) -> Date? {
    guard
      case .run(let date) = schedule.timing.next(
        after: anchor, deadline: deadline, now: now, calendar: calendar)
    else { return nil }
    return date
  }

  /// 確認 1 回を数え、記録を足す（直近 `logLimit` 件だけを残す）。
  mutating func record(_ check: WaitCheck) {
    checks += 1
    log.append(check)
    if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
  }
}

/// 条件を付けた agent の会話（CLI 名とセッション ID）と、付けたタブの workspace。
struct WaitConversation: Codable, Equatable {
  let command: String
  let sessionId: String
  let workspace: UUID?
}

/// 条件を付ける要求。作業ディレクトリと会話は、制御の層が呼び出し元タブから埋める。
struct WaitConditionRequest: Equatable {
  var description: String
  var command: String
  var intervalMinutes: Int
  var deadline: Date
  var directory: String?
  var conversation: WaitConversation?
}

/// 確認 1 回の記録。成功は「終了コード 0 で終わった」だけ。
struct WaitCheck: Codable, Equatable {
  enum Result: Equatable {
    case success
    case exited(Int32)
    case signaled(Int32)
    case limited(BackgroundProcess.Limit)
    case stopped
    case notStarted(String)
  }

  let startedAt: Date
  let endedAt: Date
  let result: Result
  /// 標準出力・標準エラーの先頭（`headBytes` まで）。
  let stdout: String
  let stderr: String

  /// 1 件に残す標準出力・標準エラーの大きさ（バイト）。
  static let headBytes = 1024

  init(startedAt: Date, endedAt: Date, result: Result, stdout: String = "", stderr: String = "") {
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.result = result
    self.stdout = stdout
    self.stderr = stderr
  }

  init(_ run: BackgroundRunResult) {
    var stdout = ""
    var stderr = ""
    if case .command(let out, let err) = run.output {
      stdout = WaitText.head(out.data, bytes: Self.headBytes)
      stderr = WaitText.head(err.data, bytes: Self.headBytes)
    }
    self.init(
      startedAt: TaskItem.storedInstant(run.startedAt),
      endedAt: TaskItem.storedInstant(run.endedAt),
      result: Result(run.ending), stdout: stdout, stderr: stderr)
  }

  private enum CodingKeys: String, CodingKey {
    case startedAt, endedAt, result, code, signal, limit, reason, stdout, stderr
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    startedAt = try c.decode(Date.self, forKey: .startedAt)
    endedAt = try c.decode(Date.self, forKey: .endedAt)
    stdout = try c.decode(String.self, forKey: .stdout)
    stderr = try c.decode(String.self, forKey: .stderr)
    switch try c.decode(String.self, forKey: .result) {
    case "success": result = .success
    case "exited": result = .exited(try c.decode(Int32.self, forKey: .code))
    case "signaled": result = .signaled(try c.decode(Int32.self, forKey: .signal))
    case "limited":
      let raw = try c.decode(String.self, forKey: .limit)
      guard let limit = Self.limits.first(where: { $0.1 == raw })?.0 else {
        throw DecodingError.dataCorruptedError(
          forKey: .limit, in: c, debugDescription: "unknown limit: \(raw)")
      }
      result = .limited(limit)
    case "stopped": result = .stopped
    case "notStarted": result = .notStarted(try c.decode(String.self, forKey: .reason))
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .result, in: c, debugDescription: "unknown result: \(other)")
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(startedAt, forKey: .startedAt)
    try c.encode(endedAt, forKey: .endedAt)
    try c.encode(result.name, forKey: .result)
    switch result {
    case .exited(let code): try c.encode(code, forKey: .code)
    case .signaled(let signal): try c.encode(signal, forKey: .signal)
    case .limited(let limit):
      try c.encode(Self.limits.first { $0.0 == limit }!.1, forKey: .limit)
    case .notStarted(let reason): try c.encode(reason, forKey: .reason)
    case .success, .stopped: break
    }
    try c.encode(stdout, forKey: .stdout)
    try c.encode(stderr, forKey: .stderr)
  }

  private static let limits: [(BackgroundProcess.Limit, String)] = [
    (.elapsed, "elapsed"), (.idle, "idle"), (.output, "output"),
  ]
}

extension WaitCheck.Result {
  /// 永続とワイヤの名前。
  var name: String {
    switch self {
    case .success: "success"
    case .exited: "exited"
    case .signaled: "signaled"
    case .limited: "limited"
    case .stopped: "stopped"
    case .notStarted: "notStarted"
    }
  }

  init(_ ending: BackgroundEnding) {
    switch ending {
    case .exited(0): self = .success
    case .exited(let code): self = .exited(code)
    case .signaled(let signal): self = .signaled(signal)
    case .limited(let limit): self = .limited(limit)
    case .stopped: self = .stopped
    case .notStarted(let failure): self = .notStarted(Self.reason(failure))
    case .toolsUnavailable(let tools):
      self = .notStarted("tools unavailable: \(tools.joined(separator: ", "))")
    }
  }

  private static func reason(_ failure: BackgroundStartFailure) -> String {
    switch failure {
    case .directoryMissing(let path): "directory not found: \(path)"
    case .launchFailed(let errno): "launch failed: \(String(cString: strerror(errno)))"
    case .invalid(let error): "invalid: \(error)"
    case .agentNotFound(let cli): "agent not found: \(cli)"
    case .agentUnsupported(let cli, _): "agent unsupported: \(cli)"
    }
  }
}

/// 解けた待ち。待っていたもの（理由・待ち始め・条件を経過ごと）と、解け方と、解けた日時。
struct WaitResolution: Codable, Equatable {
  enum How: Equatable {
    /// 確認のコマンドが成功した。確認の標準出力（`outputBytes` まで）を持つ。
    case satisfied(output: String)
    case expired
  }

  let waiting: TaskItem.Waiting
  let how: How
  let at: Date

  /// 起きたことに残す確認の標準出力の大きさ（バイト）。
  static let outputBytes = 4096

  /// 行に出す「起きたこと」（満たしたときの標準出力の 1 行目）。期限なら nil、出力が空なら空文字。
  var headline: String? {
    guard case .satisfied(let output) = how else { return nil }
    return WaitText.lines(output).first ?? ""
  }

  /// 標準出力の 2 行目以降（詳細の箱に出す）。
  var restOfOutput: [String] {
    guard case .satisfied(let output) = how else { return [] }
    return Array(WaitText.lines(output).dropFirst())
  }

  private enum CodingKeys: String, CodingKey {
    case waiting, how, at, output
  }

  init(waiting: TaskItem.Waiting, how: How, at: Date) {
    self.waiting = waiting
    self.how = how
    self.at = at
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    waiting = try c.decode(TaskItem.Waiting.self, forKey: .waiting)
    at = try c.decode(Date.self, forKey: .at)
    switch try c.decode(String.self, forKey: .how) {
    case "satisfied": how = .satisfied(output: try c.decode(String.self, forKey: .output))
    case "expired": how = .expired
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .how, in: c, debugDescription: "unknown resolution: \(other)")
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(waiting, forKey: .waiting)
    try c.encode(at, forKey: .at)
    switch how {
    case .satisfied(let output):
      try c.encode("satisfied", forKey: .how)
      try c.encode(output, forKey: .output)
    case .expired:
      try c.encode("expired", forKey: .how)
    }
  }
}

/// 確認の出力の切り詰めと行の読み方。
enum WaitText {
  /// UTF-8 の先頭 `bytes` バイトまで。文字の途中では切らない。
  static func head(_ data: Data, bytes: Int) -> String {
    var end = min(data.count, bytes)
    for _ in 0..<4 {
      if let text = String(bytes: data.prefix(end), encoding: .utf8) { return text }
      guard end > 0 else { break }
      end -= 1
    }
    // UTF-8 でない出力も、読める部分を置換文字まじりで残す。
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: data.prefix(min(data.count, bytes)), as: UTF8.self)
  }

  /// 前後の空白を除いた、空でない行。
  static func lines(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}
