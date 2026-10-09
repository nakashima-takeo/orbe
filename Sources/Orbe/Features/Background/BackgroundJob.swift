import Foundation

/// 裏で回す仕事。走らせるものと上限の組。
struct BackgroundJob: Equatable {
  enum Work: Equatable {
    case command(BackgroundCommand)
    case agent(BackgroundAgentCall)
  }

  /// 同時に走る数の枠の種類。
  enum Kind: Hashable {
    case command
    case agent
  }

  var work: Work
  var limits: BackgroundLimits

  static func command(_ command: BackgroundCommand) -> BackgroundJob {
    BackgroundJob(work: .command(command), limits: .command)
  }

  static func agent(_ call: BackgroundAgentCall) -> BackgroundJob {
    BackgroundJob(work: .agent(call), limits: .agent)
  }

  var kind: Kind {
    switch work {
    case .command: .command
    case .agent: .agent
    }
  }

  func validate() throws(BackgroundJobError) {
    switch work {
    case .command(let command):
      guard !command.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BackgroundJobError.emptyCommand
      }
      if let directory = command.directory, !directory.hasPrefix("/") {
        throw BackgroundJobError.relativeDirectory
      }
    case .agent(let call):
      guard AgentCatalog.profile(call.cli) != nil else {
        throw BackgroundJobError.unknownAgent(call.cli)
      }
      guard !call.model.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw BackgroundJobError.emptyModel
      }
      guard !call.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BackgroundJobError.emptyPrompt
      }
      guard call.tools.allSatisfy({ !$0.isEmpty }) else { throw BackgroundJobError.emptyToolName }
    }
  }
}

/// `/bin/sh -c` で走らせるコマンド。rc は読まない。作業ディレクトリの既定はホーム。
struct BackgroundCommand: Equatable {
  var script: String
  var directory: String?
}

/// 非対話の agent の呼び出し。`tools` は使ってよいツールの名前（組み込みと `mcp__` で始まる MCP のツール）。
struct BackgroundAgentCall: Equatable {
  var cli: String
  var model: String
  var tools: [String]
  var prompt: String
}

/// 1 回の実行の上限。`output` はコマンドでは標準出力、agent では最終応答の大きさ（バイト）。
struct BackgroundLimits: Equatable {
  var elapsed: TimeInterval
  var idle: TimeInterval
  var output: Int
  var stderr: Int

  static let command = BackgroundLimits(elapsed: 120, idle: 60, output: 1 << 20, stderr: 64 << 10)
  static let agent = BackgroundLimits(elapsed: 600, idle: 180, output: 1 << 20, stderr: 64 << 10)
}

enum BackgroundJobError: Error, Equatable {
  case intervalTooShort
  case noTimesOfDay
  case invalidTimeOfDay
  case emptyCommand
  case relativeDirectory
  case unknownAgent(String)
  case emptyModel
  case emptyPrompt
  case emptyToolName
}

// MARK: - 予定

/// いつ走らせるか。
enum BackgroundTiming: Equatable {
  /// 最後に走った時刻から、この間隔の後。
  case every(TimeInterval)
  /// 毎日この時刻に（その時点のタイムゾーンで数える）。
  case daily(Set<BackgroundTimeOfDay>)

  static let minimumInterval: TimeInterval = 60

  func validate() throws(BackgroundJobError) {
    switch self {
    case .every(let interval):
      guard interval >= Self.minimumInterval else { throw BackgroundJobError.intervalTooShort }
    case .daily(let times):
      guard !times.isEmpty else { throw BackgroundJobError.noTimesOfDay }
      guard times.allSatisfy({ (0...23).contains($0.hour) && (0...59).contains($0.minute) }) else {
        throw BackgroundJobError.invalidTimeOfDay
      }
    }
  }

  /// 次の出来事。規則は「数え始め（`anchor`）より後の最初の回」1 つで、初回・スリープ明け・再起動・時計の変更を同じに扱う。
  /// 返る回は今以前（過ぎている）でありうる。期限がその回以前、または期限が今以前なら「期限が来た」になる。
  func next(after anchor: Date, deadline: Date?, now: Date, calendar: Calendar) -> BackgroundNext {
    let occurrence = firstOccurrence(after: anchor, calendar: calendar)
    if let deadline, deadline <= max(occurrence, now) { return .expire(deadline) }
    return .run(occurrence)
  }

  private func firstOccurrence(after anchor: Date, calendar: Calendar) -> Date {
    switch self {
    case .every(let interval):
      return anchor.addingTimeInterval(interval)
    case .daily(let times):
      // 夏時間で存在しない時刻は、次に存在する時刻へずらす（`.nextTime`）。
      return times.compactMap {
        calendar.nextDate(
          after: anchor, matching: DateComponents(hour: $0.hour, minute: $0.minute, second: 0),
          matchingPolicy: .nextTime, repeatedTimePolicy: .first)
      }.min() ?? .distantFuture
    }
  }
}

struct BackgroundTimeOfDay: Hashable {
  var hour: Int
  var minute: Int
}

enum BackgroundNext: Equatable {
  case run(Date)
  case expire(Date)
}

/// 予定。保存は使い手が持ち、番人へは「数え始め」（最後に走った時刻。まだなら作った時刻）を添えて登録する。
struct BackgroundSchedule: Equatable {
  var job: BackgroundJob
  var timing: BackgroundTiming
  var deadline: Date?

  func validate() throws(BackgroundJobError) {
    try timing.validate()
    try job.validate()
  }
}

// MARK: - 1 回の結果

struct BackgroundRunResult: Equatable {
  /// 表示用のコマンド行（実際に走らせたもの）。
  let commandLine: String
  let startedAt: Date
  let endedAt: Date
  let ending: BackgroundEnding
  let output: BackgroundOutput
}

enum BackgroundEnding: Equatable {
  case exited(Int32)
  case signaled(Int32)
  case limited(BackgroundProcess.Limit)
  case stopped
  case notStarted(BackgroundStartFailure)
  /// 指定した MCP のツールが始まりの時点で揃わず、モデルを呼ぶ前に止めた（揃わなかった名前）。
  case toolsUnavailable([String])
}

enum BackgroundStartFailure: Error, Equatable {
  case invalid(BackgroundJobError)
  case agentUnsupported(cli: String, reason: HeadlessRefusal)
  case agentNotFound(String)
  case directoryMissing(String)
  /// `posix_spawn` の失敗（errno）。
  case launchFailed(Int32)
}

enum BackgroundOutput: Equatable {
  case none
  case command(stdout: BackgroundProcess.Captured, stderr: BackgroundProcess.Captured)
  /// `reply` は最終応答。応答が届く前に終わったら nil。
  case agent(reply: BackgroundAgentReply?, stderr: BackgroundProcess.Captured)
}

/// agent の最終応答。`isError` は CLI が失敗を報告したか。
struct BackgroundAgentReply: Equatable {
  let text: String
  let isError: Bool
}
