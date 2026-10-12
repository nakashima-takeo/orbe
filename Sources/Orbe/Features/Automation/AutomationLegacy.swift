import Foundation

/// 以前の版の形。intakes.json と、制御 API の set_intake・list_intakes が同じ形で持つので、両方がこの 1 組の型で今の
/// 定義と相互変換する。旧い定義は「取得 → 判定」で、今の形では取得元・段 1 つ「判定」・出力先タスク候補に当たる。
struct AutomationLegacyDefinition: Codable, Equatable {
  var name: String
  var fetch: AutomationLegacyFetch
  var judge: AutomationLegacyJudge
  var when: BackgroundTiming

  /// 移行した判定の段の名前。
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
struct AutomationLegacyRun: Codable, Equatable {
  var startedAt: Date
  var endedAt: Date
  var trigger: AutomationRun.Trigger
  var fetch: FetchReport
  var newItems: Int
  /// 判定を起こさなかった回は nil。
  var judge: JudgeReport?
  var withdrawn: Int
  var failure: String?

  struct FetchReport: Codable, Equatable {
    var commandLine: String
    var ending: String
    var items: Int
    var rejected: AutomationRejections
  }

  struct JudgeReport: Codable, Equatable {
    var commandLine: String
    var ending: String
    var proposed: Int
    var resolved: Int
    var rejected: AutomationRejections
  }

  /// 旧→今。判定は段「判定」の記録になり、その数は候補と対応済みの和で近似する（旧い記録は JSON の行の数を持たない）。
  /// 確定した回だけが出力先の記録を持つ。
  var run: AutomationRun {
    AutomationRun(
      startedAt: startedAt, endedAt: endedAt, trigger: trigger,
      source: AutomationStepReport(
        name: nil, commandLine: fetch.commandLine, ending: fetch.ending, count: fetch.items,
        rejected: fetch.rejected),
      fresh: newItems,
      steps: judge.map {
        [
          AutomationStepReport(
            name: AutomationLegacyDefinition.judgeStepName, commandLine: $0.commandLine,
            ending: $0.ending, count: $0.proposed + $0.resolved, rejected: AutomationRejections())
        ]
      } ?? [],
      sink: failure == nil
        ? .taskCandidates(
          AutomationTaskCandidatesReport(
            proposed: judge?.proposed ?? 0, resolved: judge?.resolved ?? 0, withdrawn: withdrawn,
            rejected: judge?.rejected ?? AutomationRejections()))
        : nil,
      failure: failure)
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

/// intakes.json。読み替え元としてだけ読む。
struct AutomationLegacyFile: Decodable {
  var version: Int
  var nextIntakeId: Int
  var nextProposalId: Int
  var intakes: [AutomationLegacyIntake]
  var proposals: [Proposal]

  struct Proposal: Decodable {
    let proposal: AutomationProposal

    init(from decoder: Decoder) throws {
      proposal = try AutomationProposal(from: decoder, owner: .intakeId)
    }
  }

  /// 今の形。前回成功の目印は、記録のうち失敗でない最新の回の開始時刻。旧い version は 1 だけ。
  var file: AutomationsFile? {
    guard version == 1 else { return nil }
    return AutomationsFile(
      version: AutomationPersistence.version, nextAutomationId: nextIntakeId,
      nextProposalId: nextProposalId,
      automations: intakes.map { intake in
        let runs = intake.runs.map(\.run)
        return Automation(
          id: intake.id, definition: intake.definition.definition, paused: intake.paused,
          createdAt: intake.createdAt, lastFetched: intake.lastFetched, reviewAll: intake.reviewAll,
          lastRunAt: intake.lastRunAt,
          lastSucceededAt: runs.first { $0.failure == nil }?.startedAt, runs: runs)
      },
      proposals: proposals.map(\.proposal))
  }
}

/// intakes.json の自動化 1 つ。
struct AutomationLegacyIntake: Decodable {
  var id: Int
  var definition: AutomationLegacyDefinition
  var paused: Bool
  var createdAt: Date
  var lastFetched: [AutomationSeen]
  var reviewAll: Bool
  var lastRunAt: Date?
  var runs: [AutomationLegacyRun]

  private enum CodingKeys: String, CodingKey {
    case id, definition, paused, createdAt, lastFetched, reviewAll, lastRunAt, runs
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(Int.self, forKey: .id)
    definition = try c.decode(AutomationLegacyDefinition.self, forKey: .definition)
    paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    lastFetched = try c.decodeIfPresent([AutomationSeen].self, forKey: .lastFetched) ?? []
    reviewAll = try c.decodeIfPresent(Bool.self, forKey: .reviewAll) ?? false
    lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
    runs = try c.decodeIfPresent([AutomationLegacyRun].self, forKey: .runs) ?? []
  }
}
