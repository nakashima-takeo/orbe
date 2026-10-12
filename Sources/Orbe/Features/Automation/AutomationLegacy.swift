import Foundation

/// 制御 API の set_intake・list_intakes が読み書きする旧い形。この 1 組の型で今の定義と相互変換する。旧い定義は
/// 「取得 → 判定」で、今の形では取得元・段 1 つ「判定」・出力先タスク候補に当たる。
struct AutomationLegacyDefinition: Codable, Equatable {
  var name: String
  var fetch: AutomationLegacyFetch
  var judge: AutomationLegacyJudge
  var when: BackgroundTiming

  /// 判定を置く段の名前。
  static let judgeStepName = "判定"

  /// 旧→今。
  var definition: AutomationDefinition {
    AutomationDefinition(
      name: name, trigger: when, source: fetch.source,
      steps: [
        AutomationStep(
          name: Self.judgeStepName,
          method: .agent(
            AutomationStepAgent(cli: judge.cli, model: judge.model, instruction: judge.instruction))
        )
      ],
      sink: .taskCandidates)
  }

  /// 今→旧。取得元があり・段がちょうど 1 つの agent・出力先がタスク候補のときだけ表せる。省略したモデルは解いた値で埋める。
  init?(_ definition: AutomationDefinition) {
    guard var source = definition.source, definition.steps.count == 1,
      case .agent(let agent) = definition.steps[0].method, source.coverage != .everything
    else { return nil }
    switch definition.sink {
    case .taskCandidates: break
    }
    if case .agent(var fetcher) = source.method {
      fetcher.model = AutomationDefinition.model(fetcher.model, finalStep: false)
      source.method = .agent(fetcher)
    }
    name = definition.name
    fetch = AutomationLegacyFetch(source: source)
    judge = AutomationLegacyJudge(
      cli: agent.cli, model: definition.model(of: agent, at: 0), instruction: agent.instruction)
    when = definition.trigger
  }
}

/// 旧い取得。モデルは必須で、取得の性質は今の集合か新着の流れ。
struct AutomationLegacyFetch: Codable, Equatable {
  var source: AutomationSource

  private enum CodingKeys: String, CodingKey {
    case command, directory, agent, model, tools, request, coverage
  }

  init(source: AutomationSource) {
    self.source = source
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if c.contains(.request) {
      _ = try c.decode(String.self, forKey: .model)
    }
    if let raw = try? c.decode(String.self, forKey: .coverage),
      ![AutomationCoverage.currentSet, .newArrivals].map(\.rawValue).contains(raw)
    {
      throw DecodingError.dataCorruptedError(
        forKey: .coverage, in: c, debugDescription: "pass currentSet or newArrivals")
    }
    source = try AutomationSource(from: decoder)
  }

  func encode(to encoder: Encoder) throws {
    try source.encode(to: encoder)
  }
}

/// 旧い判定。
struct AutomationLegacyJudge: Codable, Equatable {
  var cli: String
  var model: String
  var instruction: String

  private enum CodingKeys: String, CodingKey {
    case agent, model, instruction
  }

  init(cli: String, model: String, instruction: String) {
    self.cli = cli
    self.model = model
    self.instruction = instruction
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    cli = try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude"
    model = try c.decode(String.self, forKey: .model)
    instruction = try c.decode(String.self, forKey: .instruction)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(cli, forKey: .agent)
    try c.encode(model, forKey: .model)
    try c.encode(instruction, forKey: .instruction)
  }
}

/// 旧い回の記録。
struct AutomationLegacyRun: Encodable, Equatable {
  var startedAt: Date
  var endedAt: Date
  var trigger: AutomationRun.Trigger
  var fetch: FetchReport
  var newItems: Int
  /// 判定を起こさなかった回は nil。
  var judge: JudgeReport?
  var withdrawn: Int
  var failure: String?

  struct FetchReport: Encodable, Equatable {
    var commandLine: String
    var ending: String
    var items: Int
    var rejected: AutomationRejections
  }

  struct JudgeReport: Encodable, Equatable {
    var commandLine: String
    var ending: String
    var proposed: Int
    var resolved: Int
    var rejected: AutomationRejections
  }

  /// 今→旧。判定は最後の段の記録に、出力先の候補・対応済みと、段と出力先の捨てた行を合わせたもの。
  init(_ run: AutomationRun) {
    var sink = AutomationTaskCandidatesReport()
    if case .taskCandidates(let report) = run.sink { sink = report }
    startedAt = run.startedAt
    endedAt = run.endedAt
    trigger = run.trigger
    fetch = FetchReport(
      commandLine: run.source?.commandLine ?? "", ending: run.source?.ending ?? "",
      items: run.source?.count ?? 0, rejected: run.source?.rejected ?? AutomationRejections())
    newItems = run.fresh ?? 0
    judge = run.steps.last.map { step in
      var rejected = step.rejected
      rejected.add(sink.rejected)
      return JudgeReport(
        commandLine: step.commandLine, ending: step.ending, proposed: sink.proposed,
        resolved: sink.resolved, rejected: rejected)
    }
    withdrawn = sink.withdrawn
    failure = run.failure
  }
}
