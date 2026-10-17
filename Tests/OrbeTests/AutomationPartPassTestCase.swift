import XCTest

@testable import Orbe

/// 部品の 1 回のテストの土台。偽の実行で手段を起こし、返った結果を順に貯める。
class AutomationPartPassTestCase: OrbeTestCase {
  static let tool = AutomationGraphTests.tool
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  var jobs: FakeJobs!
  var pass: AutomationPartPass!
  var outcomes: [AutomationPartPass.Outcome] = []

  override func setUp() {
    jobs = FakeJobs()
    pass = AutomationPartPass(
      run: jobs.run, now: { [unowned self] in now },
      calendar: { Calendar(identifier: .gregorian) })
  }

  @discardableResult
  func start(
    _ part: AutomationPart, _ role: AutomationPartRole, _ input: AutomationPartPass.Input
  ) -> BackgroundRunHandle {
    pass.start(AutomationGraph.Node(part: part, role: role), input) { [unowned self] in
      outcomes.append($0)
    }
  }

  func item(_ id: String) -> AutomationItem {
    AutomationItem(id: id, link: "https://example.com/\(id)", body: "\(id) の本文", time: now)
  }

  func origin(_ id: String) -> AutomationOrigin {
    AutomationOrigin(part: "f", item: item(id))
  }

  /// 取得の部品 `f` を出た行。
  func row(_ id: String) -> AutomationPartRow {
    AutomationPartRow(id: "f:\(id)", text: #"{"id":"f:\#(id)"}"#, origin: origin(id))
  }

  func printed(_ stdout: String, exit: Int32 = 0, stderr: String = "")
    -> BackgroundRunResult
  {
    BackgroundRunResult(
      commandLine: "run", startedAt: now, endedAt: now, ending: .exited(exit),
      output: .command(
        stdout: .init(data: Data(stdout.utf8)), stderr: .init(data: Data(stderr.utf8))))
  }

  func fetched(_ ids: [String]) -> BackgroundRunResult {
    printed(
      ids.map {
        #"{"id":"\#($0)","link":"https://example.com/\#($0)","body":"\#($0) の本文","time":"2026-10-10T09:00:00Z"}"#
      }.joined(separator: "\n"))
  }

  /// `took` は上限の時計で走った長さ。
  func replied(_ text: String, took seconds: TimeInterval = 0) -> BackgroundRunResult {
    BackgroundRunResult(
      commandLine: "claude -p", startedAt: now, endedAt: now.addingTimeInterval(seconds),
      elapsed: seconds, ending: .exited(0),
      output: .agent(reply: BackgroundAgentReply(text: text, isError: false), stderr: .init()))
  }

  func agentCall(_ index: Int) -> BackgroundAgentCall? {
    guard case .agent(let call) = jobs.calls[index].job.work else { return nil }
    return call
  }

  var breach: AutomationPartPass.Breach? { outcomes.first?.breach }

  func judgeInput(_ ids: [String]) -> AutomationPartPass.Input {
    .judge(
      ids.map {
        AutomationSourcedRow(id: "f:\($0)", text: #"{"id":"f:\#($0)"}"#, origin: origin($0))
      },
      choices: AutomationJudgeChoices(
        open: [], workspaces: AutomationWorkspaces(listed: [], home: nil)))
  }

  func commandInput(_ index: Int) -> BackgroundInput? {
    guard case .command(_, let input) = jobs.calls[index].job.work else { return nil }
    return input
  }

  /// 返った順の成功の出力。失敗した回は nil。
  var outputs: [AutomationPartPass.Output?] {
    outcomes.map { outcome in
      guard case .succeeded(let output, _, _) = outcome else { return nil }
      return output
    }
  }

  var succeeded: AutomationPartPass.Output? { outputs.first ?? nil }

  var failed: String? {
    guard case .failed(let reason, _, _) = outcomes.first else { return nil }
    return reason
  }
}
