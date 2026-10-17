import Foundation

/// 自動化の部品 1 つ。手段 1 つと、予定・入力・行き先を持つ。値と組み合わせの正しさは `AutomationGraph` を作るときに検証する。
struct AutomationPart: Equatable {
  /// 自動化の中での同一性。変えれば別の部品。
  var key: String
  var name: String
  var trigger: Trigger
  /// 上流の部品の鍵。空は入力の無い部品。
  var inputs: [String]
  var method: Method
  /// 分。省略は `AutomationGraph.Node.timeoutMinutes` が解く。
  var timeoutMinutes: Int?
  /// 取得の役割の部品だけが持つ。
  var coverage: AutomationCoverage?
  var destination: Destination
  /// 入力のある部品だけが持てる。
  var inboxLimit: InboxLimit?

  static let keyLength = 1...32
  static let timeoutRange = 1...60
  static let commandTimeoutMinutes = 2
  static let agentTimeoutMinutes = 10

  enum Trigger: Equatable {
    /// 間隔か cron 式。
    case scheduled(BackgroundTiming)
    /// 押したときだけ。
    case manual
    /// 入力の行が届いたら。
    case arrival
  }

  enum Method: Equatable {
    case command(BackgroundCommand)
    case agent(AutomationPartAgent)
  }

  enum Destination: Equatable {
    /// この部品を入力に名指す部品へ、出力の行を渡す。
    case nextPart
    case taskCandidates
    case report
    /// 何も渡さない（JSON では `none`）。
    case sideEffect
  }

  /// 溜まりの上限。書かない方では捨てない。
  struct InboxLimit: Equatable {
    /// 届いてからの時間。
    var maxAgeHours: Int?
    var maxItems: Int?
  }

  /// 行を見るか——入力があり、ツールを持つ agent でない。
  var readsRows: Bool { !inputs.isEmpty && !hasTools }

  var hasTools: Bool {
    guard case .agent(let agent) = method else { return false }
    return !agent.tools.isEmpty
  }
}

/// 部品の agent。
struct AutomationPartAgent: Equatable {
  var cli: String
  /// 省略は役割の既定（`AutomationPartRole.defaultModel`）。
  var model: String?
  /// 許可の規則。MCP のツールの完全名か `Bash(<コマンドの接頭>:*)`。空はツールを持たない。
  var tools: [String]
  var instruction: String
}

/// 部品の役割。欄には持たず、部品自身の欄（入力・ツール・行き先）から `AutomationGraph` が導く。
enum AutomationPartRole: Equatable {
  /// 行を見ずに項目を出す。
  case fetch(AutomationCoverage)
  /// 行を見て行を出す。
  case process
  /// 行を見てタスク候補を出す。
  case judge
  /// 文章を報告として残す。
  case report
  /// ツールで何かをし、したことを報告として残す。
  case work
  /// 何も渡さないコマンド。
  case sideEffect

  /// Orbe へ渡す役割は sonnet、次の部品へ渡す役割は haiku。副作用はコマンドだけの役割なのでモデルを持たない。
  var defaultModel: String? {
    switch self {
    case .judge, .report, .work: "sonnet"
    case .fetch, .process: "haiku"
    case .sideEffect: nil
    }
  }
}
