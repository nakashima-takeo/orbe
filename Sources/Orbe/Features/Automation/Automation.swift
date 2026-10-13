import Foundation

/// 自動化 1 つ。定義と、Orbe が溜めるもの（出力先ごとの状態・前回の取得結果・回の記録）を持つ。
/// 出力先ごとの状態が出力先の種類に合うことはこの型が守り、それ以外の不変条件（ID の一意・定義が正しい）は
/// `AutomationStore` が保証する。
struct Automation: Equatable, Identifiable {
  /// 永続の短い整数。使い回さない。
  let id: Int
  /// 差し替えは `redefine` だけ（出力先ごとの状態を合わせるため）。
  private(set) var definition: AutomationDefinition
  /// いつも `definition.sink` の種類の状態。
  private(set) var sinkState: AutomationSinkState
  /// 止めているのは予定だけ（「今すぐ」は受ける）。
  var paused: Bool
  let createdAt: Date
  /// 最後に成功した回で取れた項目。枠の差分・候補の下げ・重なりは、すべてこの集合で言う。
  var lastFetched: [AutomationSeen]
  /// 次の回は枠の差分を掛けない（取得元か処理を書き換えた直後）。
  var reviewAll: Bool
  /// 番人の数え始め。失敗した回でも進む。
  var lastRunAt: Date?
  /// 前回成功した回の開始時刻。新着の流れの取得元に目印として渡す。
  var lastSucceededAt: Date?
  /// 新しい順。
  var runs: [AutomationRun]

  static let retainedRuns = 20

  /// `sinkState` を省くと出力先の初めの状態。渡すなら出力先の種類の状態。
  init(
    id: Int, definition: AutomationDefinition, sinkState: AutomationSinkState? = nil,
    paused: Bool, createdAt: Date, lastFetched: [AutomationSeen], reviewAll: Bool,
    lastRunAt: Date? = nil, lastSucceededAt: Date? = nil, runs: [AutomationRun]
  ) {
    let sinkState = sinkState ?? .initial(for: definition.sink)
    precondition(sinkState.belongs(to: definition.sink), "sinkState must match the sink")
    self.id = id
    self.definition = definition
    self.sinkState = sinkState
    self.paused = paused
    self.createdAt = createdAt
    self.lastFetched = lastFetched
    self.reviewAll = reviewAll
    self.lastRunAt = lastRunAt
    self.lastSucceededAt = lastSucceededAt
    self.runs = runs
  }

  /// 番人の数え始め。
  var anchor: Date { lastRunAt ?? createdAt }

  /// 定義を差し替える。出力先の種類が変われば、出力先ごとの状態は新しい出力先の初めの状態になる。
  mutating func redefine(_ definition: AutomationDefinition) {
    self.definition = definition
    if !sinkState.belongs(to: definition.sink) { sinkState = .initial(for: definition.sink) }
  }

  /// この自動化が出した候補を人がさばいたので、タスク候補の累計の `outcome` を 1 足す。出力先がタスク候補でなければ
  /// 累計を持たないので足さない。
  mutating func tally(_ outcome: WritableKeyPath<AutomationTaskCandidatesState, Int>) {
    guard case .taskCandidates(var state) = sinkState else { return }
    state[keyPath: outcome] += 1
    sinkState = .taskCandidates(state)
  }
}

extension Automation: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, definition, sinkState, paused, createdAt, lastFetched, reviewAll, lastRunAt
    case lastSucceededAt, runs
  }

  /// 定義以外は、欠けていれば無いもの（出力先ごとの状態は出力先の初めの状態）として読む。出力先ごとの状態は中身だけを
  /// 書くので、種類は定義の出力先で決める。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(Int.self, forKey: .id)
    definition = try c.decode(AutomationDefinition.self, forKey: .definition)
    switch definition.sink {
    case .taskCandidates:
      sinkState =
        try c.decodeIfPresent(AutomationTaskCandidatesState.self, forKey: .sinkState)
        .map(AutomationSinkState.taskCandidates) ?? .initial(for: definition.sink)
    }
    paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    lastFetched = try c.decodeIfPresent([AutomationSeen].self, forKey: .lastFetched) ?? []
    reviewAll = try c.decodeIfPresent(Bool.self, forKey: .reviewAll) ?? false
    lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
    lastSucceededAt = try c.decodeIfPresent(Date.self, forKey: .lastSucceededAt)
    runs = try c.decodeIfPresent([AutomationRun].self, forKey: .runs) ?? []
  }
}

/// 自動化の定義。トリガー → 取得元（任意）→ 処理の段 0 個以上 → 出力先。
struct AutomationDefinition: Equatable, Codable {
  var name: String
  var trigger: BackgroundTiming
  var source: AutomationSource?
  var steps: [AutomationStep]
  var sink: AutomationSink

  /// 省略したモデルを解く。最後の段は判断を担うので sonnet、それ以外の段と取得元は haiku。保存は省略のまま持ち、
  /// 走らせるとき・画面に出すとき・やり直しの比較がどれもここを通す——段の並びを変えたら既定も追従させるため。
  static func model(_ model: String?, finalStep: Bool) -> String {
    model ?? (finalStep ? "sonnet" : "haiku")
  }

  /// 段 `index` の agent が走るモデル。
  func model(of agent: AutomationStepAgent, at index: Int) -> String {
    Self.model(agent.model, finalStep: index == steps.count - 1)
  }

  /// 何をするか。名前・トリガー・取得の性質・段の名前を除き、モデルは解いた値で持つ。これが変わる書き換えはやり直しになる。
  var work: Work {
    var source = source?.method
    if case .agent(var agent) = source {
      agent.model = Self.model(agent.model, finalStep: false)
      source = .agent(agent)
    }
    let steps = steps.enumerated().map { index, step -> AutomationStep.Method in
      guard case .agent(var agent) = step.method else { return step.method }
      agent.model = model(of: agent, at: index)
      return .agent(agent)
    }
    return Work(source: source, steps: steps, sink: sink)
  }

  struct Work: Equatable {
    let source: AutomationSource.Method?
    let steps: [AutomationStep.Method]
    let sink: AutomationSink
  }
}

/// 何をどう取るかと、取れたものが何を表すか。
struct AutomationSource: Equatable {
  var method: Method
  var coverage: AutomationCoverage

  /// コマンドは 1 行 1 項目の JSON を自分で出し、agent は渡したツールだけで依頼文どおりに取る。
  enum Method: Equatable {
    case command(BackgroundCommand)
    case agent(AutomationSourceAgent)
  }
}

/// 取得の性質——取得結果が何を表すか。枠の差分を掛けるかと、候補をいつ下げるかがこれで決まる。
enum AutomationCoverage: String {
  /// その時点の全体（例: 自分が担当の未完了課題）。取得から消えたリンクの候補を下げる。
  case currentSet
  /// 新着だけ（例: 自分宛の新しい DM）。取得から消えても下げず、判定が対応済みとしたときだけ下げる。
  case newArrivals
  /// 毎回全件。前回の取得結果との差分を掛けない。
  case everything
}

/// 取得元の agent。読み取りの MCP ツールだけを持つ。
struct AutomationSourceAgent: Equatable {
  var cli: String
  var model: String?
  var tools: [String]
  var request: String
}

/// 処理の段 1 つ。JSON の行を受けて JSON の行を出す。状態を持たない。
struct AutomationStep: Equatable {
  var name: String
  var method: Method

  enum Method: Equatable {
    case command(BackgroundCommand)
    case agent(AutomationStepAgent)
  }
}

/// 段の agent。ツールを持たない閉じた形でだけ走る——外から届いた文面を読む役に、何かをさせる手段を渡さないため。
struct AutomationStepAgent: Equatable {
  var cli: String
  var model: String?
  var instruction: String
}

/// 出力先。最後の段の出力の形と、その届け方・確定のしかたを決める。
enum AutomationSink: Equatable {
  /// タスクの候補として覚え、人がさばく。
  case taskCandidates
}

/// 出力先ごとの状態。種類は `AutomationSink` と同じ並びで、出力先の種類を足すときはここにも足す。
enum AutomationSinkState: Equatable {
  case taskCandidates(AutomationTaskCandidatesState)

  static func initial(for sink: AutomationSink) -> Self {
    switch sink {
    case .taskCandidates: .taskCandidates(AutomationTaskCandidatesState())
    }
  }

  /// `sink` の種類の状態か。
  func belongs(to sink: AutomationSink) -> Bool {
    switch (self, sink) {
    case (.taskCandidates, .taskCandidates): true
    }
  }
}

/// タスク候補の出力先の累計——この自動化の出す候補が役に立っているかを読む数。人がさばいたときだけ増え、減らない。
/// 候補は誰も持たなくなると忘れるので、候補から数え直さず、さばいたときに数えて持つ。
struct AutomationTaskCandidatesState: Codable, Equatable {
  /// タスクにした数。
  var accepted = 0
  /// 捨てた数。
  var dismissed = 0
}

/// 取得の出力 1 行。`id` は自動化の中での同一性（段を通しても保つ）、`link` は自動化をまたぐ同一性。
struct AutomationItem: Equatable {
  let id: String
  let link: String
  let body: String
  let time: Date
}

/// 前回の取得結果に覚えておく 1 項目。
struct AutomationSeen: Codable, Equatable {
  let id: String
  let link: String
}

/// 判定が出した候補。リンクは全候補を通じて一意。
struct AutomationProposal: Equatable, Identifiable {
  let id: Int
  /// 候補を出した自動化（履歴。棚に出す自動化は `AutomationStore.shelf(of:)` が導く）。
  let automationId: Int
  let item: AutomationItem
  let title: String
  let due: TaskItem.DueDate?
  let proposedAt: Date
  var state: State

  enum State: Equatable {
    case open
    case accepted(taskId: Int)
    case dismissed
    /// 判定が対応済みとした。
    case resolved
  }
}

/// 1 回の記録。失敗した回は、届いたところまでを持つ。
struct AutomationRun: Codable, Equatable {
  enum Trigger: String, Codable {
    case schedule
    case now
  }

  var startedAt: Date
  var endedAt: Date
  var trigger: Trigger
  /// 取得元の無い自動化と、取得元まで行かなかった回は nil。
  var source: AutomationStepReport?
  /// 枠の差分と出力先の取り込みを経て、段に回した項目の数。取得元から先へ進まなかった回は nil。
  var fresh: Int?
  var steps: [AutomationStepReport]
  /// 確定した回だけが持つ。
  var sink: AutomationSinkReport?
  /// 失敗した回の理由。失敗した回は前回の取得結果も出力先の状態も動かさない。
  var failure: String?
}

/// 取得元か段 1 つの記録。`count` は JSON の行として読めた数（取得元は項目として読めた数）、`rejected` は読めなかった行。
struct AutomationStepReport: Codable, Equatable {
  /// 段の名前。取得元は持たない。
  var name: String?
  var commandLine: String
  var ending: String
  var count: Int
  var rejected: AutomationRejections
}

/// 出力先の記録。
enum AutomationSinkReport: Equatable {
  case taskCandidates(AutomationTaskCandidatesReport)
}

struct AutomationTaskCandidatesReport: Codable, Equatable {
  /// 受けた候補の数。
  var proposed = 0
  /// 対応済みにした候補の数。
  var resolved = 0
  /// この回の確定で下げた（出ていた）候補の数。
  var withdrawn = 0
  /// propose・resolve として読めなかった行と、確かめ・確定で捨てた行。
  var rejected = AutomationRejections()
}

/// 捨てた行。理由は最初の数件だけ残す。
struct AutomationRejections: Codable, Equatable {
  var count = 0
  var reasons: [String] = []

  static let retainedReasons = 5

  mutating func add(_ reason: String) {
    count += 1
    if reasons.count < Self.retainedReasons { reasons.append(reason) }
  }

  mutating func add(_ other: AutomationRejections) {
    count += other.count
    reasons += other.reasons.prefix(Self.retainedReasons - reasons.count)
  }
}

enum AutomationError: Error, Equatable {
  case automationNotFound(Int)
  case proposalNotFound(Int)
  /// 人の判断待ちでない候補をさばこうとした（判定の確定や、別の口のさばきと行き違った）。
  case proposalNotOpen(Int)
  /// 値か組み合わせが不変条件に反する。
  case invalid(String)
  /// 走っている回がある。
  case running(Int)
}
