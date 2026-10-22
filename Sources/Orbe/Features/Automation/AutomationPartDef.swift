import Foundation

/// 自動化の部品（実体）の ID。Orbe が振り、使い回さない。状態と履歴はこれだけを指す（鍵はただの呼び名）。
struct AutomationPartID: Hashable, Comparable, CustomStringConvertible {
  let rawValue: Int

  init(_ rawValue: Int) { self.rawValue = rawValue }

  var description: String { "\(rawValue)" }

  static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// 部品の定義の ID。定義は書き換えずに足すので、ID がそのまま中身の版になる。
struct AutomationDefID: Hashable, Comparable {
  let rawValue: Int

  init(_ rawValue: Int) { self.rawValue = rawValue }

  static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// 動作の定義——部品が何をするか: 手段・上限・出力の性質・行き先。自動化の部品がどれを使うかは `AutomationPart.defId` が指す。
struct AutomationActionDef: Equatable {
  var method: Method
  /// 分。省略は `AutomationGraph.Node.timeoutMinutes` が解く。
  var timeoutMinutes: Int?
  /// 出力の性質。行を出す部品だけが持つ（取得は必ず書き、処理は省けば出来事の流れ）。
  var coverage: AutomationCoverage?
  var destination: Destination

  static let timeoutRange = 1...60
  static let commandTimeoutMinutes = 2
  static let agentTimeoutMinutes = 10

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

  var hasTools: Bool {
    guard case .agent(let agent) = method else { return false }
    return !agent.tools.isEmpty
  }
}

/// 自動化の部品（実体）。自動化の中のどこに置き、どう呼び、いつ動くかと、使う部品の定義を持つ。
struct AutomationPart: Equatable {
  let id: AutomationPartID
  var key: String
  var name: String
  var trigger: Trigger
  /// 受け手として 1 回に取る件数の上限。入力のある部品だけが持てる。
  var maxItems: Int?
  var defId: AutomationDefID

  static let keyLength = 1...32

  enum Trigger: Equatable {
    /// 間隔か cron 式。
    case scheduled(BackgroundTiming)
    /// 押したときだけ。
    case manual
    /// 入力の行が届いたら。
    case arrival
  }
}

/// 部品どうしのつながり（受け手の 1 つの入力）。受け手が取り方を持つ。
struct AutomationPartEdge: Hashable {
  let from: AutomationPartID
  var take: AutomationTake
  /// 古さの上限（時間）。項目は有効になってから、出来事は作られてからの時間で数える。
  var maxAgeHours: Int?
}

/// 受け手の取り方。
enum AutomationTake: String, Hashable {
  /// まだ受け取っていない行だけ。
  case new
  /// 回ごとに、今有効な項目と残す期間の内の出来事のすべて。
  case all
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

  var isFetch: Bool {
    if case .fetch = self { true } else { false }
  }
}
