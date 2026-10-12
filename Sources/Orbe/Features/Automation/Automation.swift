import Foundation

/// 受信 1 つ。定義（名前・取得・判定・いつ）と、回を重ねて溜まるもの（前回の取得結果・回の記録）を持つ。
/// 不変条件（ID の一意・定義が正しい）は `AutomationStore` が保証する。
struct Automation: Equatable, Identifiable {
  /// 永続の短い整数。使い回さない。
  let id: Int
  var definition: AutomationDefinition
  /// 止めているのは予定だけ（「今すぐ」は受ける）。
  var paused: Bool
  let createdAt: Date
  /// 最後に成功した回で取れた項目。新しい項目・提案の下げ・重なりは、すべてこの集合で言う。
  var lastFetched: [AutomationSeen]
  /// 次の回は、取れた全件を新しい項目とみなす（取得か判定を書き換えた直後）。
  var reviewAll: Bool
  var lastRunAt: Date?
  /// 新しい順。
  var runs: [AutomationRun]

  static let retainedRuns = 20

  /// 番人の数え始め。
  var anchor: Date { lastRunAt ?? createdAt }
}

extension Automation: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, definition, paused, createdAt, lastFetched, reviewAll, lastRunAt, runs
  }

  /// 定義以外は、欠けていれば無いものとして読む。
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(Int.self, forKey: .id)
    definition = try c.decode(AutomationDefinition.self, forKey: .definition)
    paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    lastFetched = try c.decodeIfPresent([AutomationSeen].self, forKey: .lastFetched) ?? []
    reviewAll = try c.decodeIfPresent(Bool.self, forKey: .reviewAll) ?? false
    lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
    runs = try c.decodeIfPresent([AutomationRun].self, forKey: .runs) ?? []
  }
}

/// 受信の定義。制御 API・MCP・`orb intake set`・intakes.json が同じ形で読み書きする。
struct AutomationDefinition: Equatable, Codable {
  var name: String
  var fetch: AutomationFetch
  var judge: AutomationJudge
  var when: BackgroundTiming
}

/// 何をどう取るかと、取れたものが何を表すか。
struct AutomationFetch: Equatable {
  var method: Method
  var coverage: AutomationCoverage

  /// コマンドは 1 行 1 項目の JSON を自分で出し、agent は渡したツールだけで依頼文どおりに取る。
  enum Method: Equatable {
    case command(BackgroundCommand)
    case agent(AutomationAgentFetch)
  }
}

/// 取得の性質——取得結果が何を表すか。Orbe が提案を下げるかはこれで決まる。
enum AutomationCoverage: String {
  /// その時点の全体（例: 自分が担当の未完了課題）。取得から消えたリンクの提案を下げる。
  case currentSet
  /// 新着だけ（例: 自分宛の新しい DM）。取得から消えても下げず、判定が対応済みとしたときだけ下げる。
  case newArrivals
}

struct AutomationAgentFetch: Equatable {
  var cli: String
  var model: String
  var tools: [String]
  var request: String
}

/// 新しい項目を読んでタスクにすべきものを提案する役。ツールを持たない閉じた形でだけ走る。
struct AutomationJudge: Equatable {
  var cli: String
  var model: String
  var instruction: String
}

/// 取得の出力 1 行。`id` は受信の中での同一性、`link` は受信をまたぐ同一性。
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

/// 判定が出した提案。リンクは全提案を通じて一意。
struct AutomationProposal: Equatable, Identifiable {
  let id: Int
  /// 提案した受信（履歴。棚に出す受信は `AutomationStore.shelf(of:)` が導く）。
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

/// 1 回の記録。
struct AutomationRun: Codable, Equatable {
  enum Trigger: String, Codable {
    case schedule
    case now
  }

  var startedAt: Date
  var endedAt: Date
  var trigger: Trigger
  var fetch: AutomationFetchReport
  /// 判定に回した項目の数。
  var newItems: Int
  /// 判定を起こさなかった回は nil。
  var judge: AutomationJudgeReport?
  /// この回の確定で下げた（出ていた）提案の数。
  var withdrawn: Int
  /// 失敗した回の理由。失敗した回は取得済みも提案も動かさない。
  var failure: String?
}

/// 取得の段の記録。
struct AutomationFetchReport: Codable, Equatable {
  var commandLine: String
  var ending: String
  /// 取れた項目の数。
  var items: Int
  var rejected: AutomationRejections
}

/// 判定の段の記録。
struct AutomationJudgeReport: Codable, Equatable {
  var commandLine: String
  var ending: String
  /// 受けた提案の数。
  var proposed: Int
  /// 対応済みにした提案の数。
  var resolved: Int
  var rejected: AutomationRejections
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
}

enum AutomationError: Error, Equatable {
  case automationNotFound(Int)
  case proposalNotFound(Int)
  /// 人の判断待ちでない提案をさばこうとした（判定の確定や、別の口のさばきと行き違った）。
  case proposalNotOpen(Int)
  /// 値か組み合わせが不変条件に反する。
  case invalid(String)
  /// 走っている回がある。
  case running(Int)
}
