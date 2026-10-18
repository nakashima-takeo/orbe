import Foundation

/// 自動化 1 つ。定義（名前・通知・部品のグラフ）と、Orbe が溜めるもの（部品ごとの状態・採用/見送りの累計）を持つ。部品ごとの
/// 状態がグラフの部品とちょうど揃うことは `AutomationStore` が保証する。
struct Automation: Equatable, Identifiable {
  /// 永続の短い整数。使い回さない。
  let id: Int
  var name: String
  /// 部品の回を知らせる先。nil は知らせない。何をするかには入らない。
  var notify: AutomationNotify?
  var graph: AutomationGraph
  /// 止めているのは時刻による予定と起動時の起こしだけ。
  var paused: Bool
  let createdAt: Date
  /// 判定の部品を持つ間だけ数え、持たなくなれば 0 に戻る。
  var tally: AutomationTally
  /// 部品の鍵ごとの状態。
  var parts: [String: AutomationPartState]

  /// 外の形＝保存の形。
  var definition: AutomationDefinition {
    AutomationDefinition(name: name, notify: notify, parts: graph.parts)
  }

  /// 判定の部品を持つか。タスク候補の棚・累計・重なりはこれを持つ自動化の単位。
  var judges: Bool { graph.nodes.contains { $0.role == .judge } }

  /// 部品の状態。グラフの部品はいつも状態を持つ。
  func state(_ key: String) -> AutomationPartState {
    guard let state = parts[key] else { preconditionFailure("every part has a state: \(key)") }
    return state
  }

  /// 部品の回をすべて、新しい順に混ぜたもの。
  var runs: [AutomationKeyedRun] {
    parts.flatMap { key, state in state.runs.map { AutomationKeyedRun(part: key, run: $0) } }
      .sorted { ($0.run.startedAt, $0.part) > ($1.run.startedAt, $1.part) }
  }
}

/// どの部品の回か。
struct AutomationKeyedRun: Equatable {
  let part: String
  let run: AutomationPartRun
}

/// 自動化の定義（外の形＝保存の形）。形だけを読み、値と組み合わせは `checked()` が検証する。
struct AutomationDefinition: Equatable, Codable {
  var name: String
  var notify: AutomationNotify?
  var parts: [AutomationPart]

  /// 名前は 1 行に整え、部品はグラフとして検証する。名前はタスクのタイトルと同じ 1 行の規則（前後の空白を除いて保存）。
  func checked() throws(AutomationError) -> (name: String, graph: AutomationGraph) {
    let name: String
    do throws(TaskStoreError) {
      name = try TaskStore.validTitle(self.name)
    } catch {
      throw .invalid("name: must be a single non-empty line")
    }
    return (name, try AutomationGraph(parts))
  }
}

/// 回を知らせる先。
enum AutomationNotify: String, CaseIterable {
  /// メニューバーのピルと音。
  case menuBar
  /// macOS の通知センターと音。許可が無い回はメニューバーのピルに出る。
  case notificationCenter
}

/// 取得の性質——取得結果が何を表すか。差分を掛けるかと、候補をいつ下げるかがこれで決まる。
enum AutomationCoverage: String {
  /// その時点の全体（例: 自分が担当の未完了課題）。取得から消えたリンクの候補を下げる。
  case currentSet
  /// 新着だけ（例: 自分宛の新しい DM）。取得から消えても下げず、判定が対応済みとしたときだけ下げる。
  case newArrivals
  /// 毎回全件。前回の出力との差分を掛けない。
  case everything
}

/// 部品 1 つの状態。
struct AutomationPartState: Equatable {
  /// 部品を足した時刻。一度も回っていない部品の数え始め。
  var addedAt: Date
  var lastRunAt: Date?
  /// 前回成功した回の開始時刻。新着の流れの取得に目印として渡す。
  var succeededAt: Date?
  /// 前回の出力（取得だけ）。差分・候補の持ち主・重なりはこの集合で言う。
  var lastOutput: [AutomationSeen] = []
  /// まだ回の記録に載せていない捨てた数（積む時点の件数の上限・判定へ出どころの無いまま届いた行と、取る行が 0 件だった契機で
  /// 捨てた行）。
  var pendingDrops = AutomationDrops()
  /// 出力が決まりを外した最初の回の印。何をするかが変わるまで残る。
  var breach: AutomationBreachMark?
  /// 新しい順。
  var runs: [AutomationPartRun] = []
  /// 溜まりの件数（メモリだけ。行は DB にだけある）。
  var inbox = 0
  /// 溜まりの最も新しい通し番号（メモリだけ。空なら 0）。
  var newestSeq = 0

  static let retainedRuns = 20

  /// 番人の数え始め。回が記録されたときだけ進む。
  var anchor: Date { lastRunAt ?? addedAt }
}

/// 判定の部品を持つ自動化の候補の累計——この自動化の出す候補が役に立っているかを読む数。人がさばいたときだけ増える。
struct AutomationTally: Equatable {
  /// タスクにした数。
  var accepted = 0
  /// 捨てた数。
  var dismissed = 0
}

/// 取得の出力 1 行。`id` は部品の中での同一性、`link` は自動化をまたぐ同一性。
struct AutomationItem: Equatable {
  let id: String
  let link: String
  let body: String
  let time: Date
}

/// 前回の出力に覚えておく 1 項目。
struct AutomationSeen: Codable, Equatable {
  let id: String
  let link: String
}

/// 判定が出した候補。リンクは全候補を通じて一意。
struct AutomationProposal: Equatable, Identifiable {
  let id: Int
  /// 候補を出した自動化（履歴。棚に出す自動化は `AutomationStore.shelf(of:)` が導く）。
  let automationId: Int
  /// 出した判定の部品。
  let partKey: String
  /// 出どころの取得の部品。
  let sourcePartKey: String
  /// 出どころの項目（`id` は接頭の無い元の id）。
  let item: AutomationItem
  let title: String
  let due: TaskItem.DueDate?
  /// 付け先の `Workspace.persistentId`（判定が決める）。解決できない参照は「なし」と同じに扱う。
  let workspace: UUID?
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

extension AutomationProposal.State {
  /// 永続とワイヤの語（open / accepted / dismissed / resolved）。
  var name: String {
    switch self {
    case .open: "open"
    case .accepted: "accepted"
    case .dismissed: "dismissed"
    case .resolved: "resolved"
    }
  }
}

enum AutomationError: Error, Equatable {
  case automationNotFound(Int)
  case proposalNotFound(Int)
  /// 人の判断待ちでない候補をさばこうとした（判定の確定や、別の口のさばきと行き違った）。
  case proposalNotOpen(Int)
  /// 値か組み合わせが不変条件に反する。
  case invalid(String)
  case partNotFound(Int, String)
  /// 流している途中に流そうとした。
  case flowing(Int)
  /// 自動化の DB を使えない、または書けなかった。
  case unavailable(String)
}
