import Foundation

// 裏で回す仕組みの失敗と終わり方を、AI と人に返す英文へ写す（受信と待ちの条件が共有する）。

extension BackgroundJobError {
  var message: String {
    switch self {
    case .intervalTooShort: "the interval must be at least 1 minute"
    case .intervalTooLong: "the interval must be at most 10080 minutes (7 days)"
    case .noTimesOfDay: "no times of day"
    case .invalidTimeOfDay: "a time of day is out of range"
    case .emptyCommand: "command is empty"
    case .relativeDirectory: "directory is not an absolute path"
    case .unknownAgent(let cli): "agent \(cli) is not supported"
    case .emptyModel: "model is empty"
    case .emptyPrompt: "prompt is empty"
    case .emptyToolName: "a tool name is empty"
    }
  }
}

extension BackgroundEnding {
  /// 回の記録に残す終わり方。
  var text: String {
    switch self {
    case .exited(let code): "exited \(code)"
    case .signaled(let signal): "killed by signal \(signal)"
    case .limited(.elapsed): "stopped at the time limit"
    case .limited(.idle): "stopped after producing no output for too long"
    case .limited(.output): "stopped at the output limit"
    case .stopped: "stopped"
    case .notStarted(let failure): "not started (\(failure.text))"
    case .toolsUnavailable(let tools): "tools unavailable: \(tools.joined(separator: ", "))"
    }
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
    case .launchFailed(let code): "launch failed: \(String(cString: strerror(code)))"
    }
  }
}
