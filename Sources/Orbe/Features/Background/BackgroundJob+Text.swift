import Foundation

// 裏で回す仕組みの失敗と終わり方を、AI と人に返す英文へ写す（自動化と待ちの条件が共有する）。

extension BackgroundJobError {
  var message: String {
    switch self {
    case .intervalTooShort: "the interval must be at least 1 minute"
    case .intervalTooLong: "the interval must be at most 10080 minutes (7 days)"
    case .emptyCommand: "command is empty"
    case .relativeDirectory: "directory is not an absolute path"
    case .unknownAgent(let cli): "agent \(cli) is not supported"
    case .emptyModel: "model is empty"
    case .emptyPrompt: "prompt is empty"
    case .emptyToolName: "a tool name is empty"
    }
  }
}

extension BackgroundCronError {
  var message: String {
    switch self {
    case .fieldCount: "expected 5 fields: minute hour day month weekday"
    case .invalidField(let field, let text): "invalid \(field.rawValue) field: \(text)"
    case .dayAndWeekday: "leave the day of month or the weekday as *"
    case .neverMatches: "never matches"
    }
  }
}

extension BackgroundEnding {
  /// `toolsUnavailable` の英文。
  static func unavailable(_ tools: [String]) -> String {
    "tools unavailable: \(tools.joined(separator: ", "))"
  }
}

extension BackgroundStartFailure {
  var text: String {
    switch self {
    case .invalid(let error): error.message
    case .agentUnsupported(let cli, let reason):
      "\(cli) cannot run in the background: \(reason.message)"
    case .agentNotFound(let cli): "\(cli) is not installed"
    case .directoryMissing(let directory): "directory missing: \(directory)"
    case .workDirectoryFailed(let directory): "could not create the work directory: \(directory)"
    case .launchFailed(let code): "launch failed: \(String(cString: strerror(code)))"
    }
  }
}
