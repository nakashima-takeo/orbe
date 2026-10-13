import Foundation
import OrbeSessionLog

/// 取得元を走らせるものの組み立てと、その出力の読み取り。
extension AutomationRunner {
  static func sourceJob(_ source: AutomationSource, since: Date?) -> BackgroundJob {
    switch source.method {
    case .command(let command):
      var input = BackgroundInput()
      if let since { input.environment["ORBE_SINCE"] = SessionEvent.iso8601(since) }
      return .command(command, input: input)
    case .agent(let agent):
      return .agent(
        BackgroundAgentCall(
          cli: agent.cli, model: AutomationDefinition.model(agent.model, finalStep: false),
          tools: agent.tools, prompt: AutomationPrompts.fetch(request: agent.request, since: since))
      )
    }
  }

  static func readSource(_ result: BackgroundRunResult)
    -> AutomationPrompts.FetchReading
  {
    switch AutomationRunOutput.text(result, role: "fetch") {
    case .failure(let failure): .failed(failure.reason, rejected: AutomationRejections())
    case .success(let text): AutomationPrompts.readFetch(text)
    }
  }
}
