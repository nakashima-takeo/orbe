import XCTest

@testable import Orbe

/// 部品の 1 回のテストの土台。偽の実行で手段を起こし、返った結果を順に貯める。
class AutomationNodePassTestCase: OrbeTestCase {
  static let tool = AutomationGraphTests.tool
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  var jobs: FakeJobs!
  var runSessions: AutomationRunSessions!
  var pass: AutomationNodePass!
  var outcomes: [AutomationNodePass.Outcome] = []
  /// 最後に起こした部品の鍵（失敗の英文を組む）。
  var startedKey = ""

  override func setUp() {
    jobs = FakeJobs()
    runSessions = AutomationRunSessions()
    pass = AutomationNodePass(
      run: jobs.run, now: { [unowned self] in now },
      calendar: { Calendar(identifier: .gregorian) }, runSessions: runSessions)
  }

  @discardableResult
  func start(
    _ part: AutomationDefinition.Node, _ role: AutomationNodeRole,
    _ input: AutomationNodePass.Input
  ) -> BackgroundRunHandle {
    startedKey = part.key
    let node = AutomationGraph.Node(
      entity: AutomationNode(
        id: AutomationNodeID(1), key: part.key, name: part.name, trigger: part.trigger,
        maxItems: part.maxItems, defId: AutomationDefID(1)),
      action: part.action,
      inputs: part.from.enumerated().map {
        AutomationNodeEdge(
          from: AutomationNodeID(100 + $0.offset), take: $0.element.take,
          maxAgeHours: $0.element.maxAgeHours)
      }, role: role)
    return pass.start(node, input) { [unowned self] in outcomes.append($0) }
  }

  func item(_ id: String) -> AutomationItem {
    AutomationItem(id: id, link: "https://example.com/\(id)", body: "\(id) の本文", time: now)
  }

  func origin(_ id: String) -> AutomationIntake.Origin {
    AutomationIntake.Origin(part: AutomationNodeID(9), row: .event(Self.number(id)), item: item(id))
  }

  /// 取得の部品 `f` を出た行。
  func row(_ id: String) -> AutomationNodeRow {
    AutomationNodeRow(
      id: "f:\(id)", text: #"{"id":"f:\#(id)"}"#, origin: origin(id),
      source: .event(Self.number(id)))
  }

  /// id ごとに決まる、出す側の行の番号（見本）。
  static func number(_ id: String) -> Int {
    id.utf8.reduce(7) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
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

  func replied(_ text: String, isError: Bool = false) -> BackgroundRunResult {
    BackgroundRunResult(
      commandLine: "claude -p", startedAt: now, endedAt: now, elapsed: 0, ending: .exited(0),
      output: .agent(reply: BackgroundAgentReply(text: text, isError: isError), stderr: .init()))
  }

  /// agent の CLI が最終応答を返して終わった（結果は道具で受けているので、応答の文は読まない）。
  func done() -> BackgroundRunResult {
    replied("done")
  }

  /// 呼び出し `index` の agent の回の相手（回が終わっていれば nil）。
  func session(_ index: Int) -> AutomationRunSession? {
    agentCall(index)?.orbe.flatMap { runSessions.session($0.token) }
  }

  /// 呼び出し `index` の agent が、その回の道具を呼ぶ。
  @discardableResult
  func use(_ index: Int, _ tool: AutomationRunSession.Tool, _ arguments: [String: Any] = [:])
    -> AutomationRunSession.Reply
  {
    guard let session = session(index) else {
      XCTFail("回の相手が無い: \(index)")
      return .refused("")
    }
    return session.call(tool.rawValue, arguments)
  }

  /// 呼び出し `index` の agent が、入力の行をすべて読む。
  func readAll(_ index: Int) {
    var offset: Int? = 0
    while let next = offset {
      let reply = use(
        index, .readRunRows, ["offset": next, "limit": AutomationRunSession.pageLimit])
      let head = try? JSONSerialization.jsonObject(with: Data((reply.texts.first ?? "").utf8))
      offset = (head as? [String: Any])?["next"] as? Int
    }
  }

  func agentCall(_ index: Int) -> BackgroundAgentCall? {
    guard case .agent(let call) = jobs.calls[index].job.work else { return nil }
    return call
  }

  var breach: AutomationRejections? { outcomes.first?.breach }

  func judgeInput(_ ids: [String]) -> AutomationNodePass.Input {
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
  var outputs: [AutomationNodePass.Output?] {
    outcomes.map { outcome in
      guard case .succeeded(let output, _, _) = outcome else { return nil }
      return output
    }
  }

  var succeeded: AutomationNodePass.Output? { outputs.first ?? nil }

  /// 最初の失敗の、AI が読む英文。
  var failed: String? {
    guard case .failed(let failure, let execution, let breach) = outcomes.first else { return nil }
    return failure.text(part: startedKey, ending: execution.ending, breach: breach)
  }
}
