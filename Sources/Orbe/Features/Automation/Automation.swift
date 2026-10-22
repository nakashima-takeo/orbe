import Foundation

/// 自動化 1 つ。自動化は部品ではなく、名前・通知・止めた時刻・版の番号と、部品とつながり（グラフ）で中身を表す。部品ごとの
/// 状態がグラフの部品とちょうど揃うことは `AutomationStore` が保証する。
struct Automation: Equatable, Identifiable {
  /// 永続の短い整数。使い回さない。
  let id: Int
  var name: String
  /// 部品の回を知らせる先。nil は知らせない。何をするかには入らない。
  var notify: AutomationNotify?
  var graph: AutomationGraph
  /// 止めた時刻。止めているのは時刻による予定と起動時の起こしだけ。
  var pausedAt: Date?
  /// 定義の版。名前・通知・部品・つながりのどれかが変わるたびに 1 増える（古い定義からの書き換えを断る印）。
  var version: Int
  let createdAt: Date
  /// 部品ごとの状態。
  var parts: [AutomationPartID: AutomationPartState]

  var paused: Bool { pausedAt != nil }

  /// 外の形（部品に ID を添える）。
  var definition: AutomationDefinition {
    AutomationDefinition(name: name, notify: notify, parts: graph.parts)
  }

  /// 判定の部品を持つか。タスク候補の棚・重なりはこれを持つ自動化の単位。
  var judges: Bool { !graph.judges.isEmpty }

  /// 部品の状態。グラフの部品はいつも状態を持つ。
  func state(_ id: AutomationPartID) -> AutomationPartState {
    guard let state = parts[id] else { preconditionFailure("every part has a state: \(id)") }
    return state
  }

  /// 最後の回が失敗した部品があるか。
  var failing: Bool {
    graph.nodes.contains { state($0.id).runs.first?.failed == true }
  }

  /// 部品の回をすべて、新しい順に混ぜたもの。
  var runs: [AutomationRunRecord] {
    parts.values.flatMap(\.runs).sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
  }
}

/// 定義が今の検証を通らない自動化。動かず、定義を直すか消すまで、行から組めた分と理由を持って場所を占める。持っていた候補は
/// 忘れない。
struct AutomationUnreadable: Equatable, Identifiable {
  let id: Int
  /// 1 行として読めた名前。読めなければ nil。
  let name: String?
  let version: Int
  /// 行から組めた分の定義（外の形の JSON）。
  let definition: String
  /// 読めない理由（定義の中の場所で言う英文）。
  let reason: String
  /// 外していない部品。
  let parts: [AutomationPartID]
}

/// 回を知らせる先。
enum AutomationNotify: String, CaseIterable {
  /// メニューバーのピルと音。
  case menuBar
  /// macOS の通知センターと音。許可が無い回はメニューバーのピルに出る。
  case notificationCenter
}

/// 出力の性質——出した行が何を表すか。何が今有効かを、出す側が決める。
enum AutomationCoverage: String {
  /// 今の集合（状態）。結果にある間有効で、結果から消えたら無効になる（例: 自分が担当の未完了課題）。
  case currentSet
  /// 出来事の流れ（記録）。足すだけで、残す期間を過ぎたら消える（例: 自分宛の新しい DM）。
  case newArrivals
}

/// 部品 1 つの状態。行と記録の正は DB で、メモリは画面と予定が同期で読む分だけを、部品ごとに DB から読み直して持つ——自分の
/// 状態は `AutomationDatabase.state(of:)`、読めば取る行は `AutomationMemory.recount`。差分を手で当てないので、DB とずれない。
struct AutomationPartState: Equatable {
  /// 部品を足した時刻。一度も回っていない部品の数え始め。
  var addedAt: Date
  /// 直近の回の記録（新しい順に `retainedRuns` 件まで）。
  var runs: [AutomationRunRecord] = []
  /// 最新の成功した回の開始時刻。新着の流れの取得に目印として渡す。
  var succeededAt: Date?
  /// 出力が決まりを外した最初の回の記録。何をするかが変わるまで残る。
  var breach: AutomationRunRecord?
  /// 受け手として今読めば取る行。入力の無い部品は 0 件。
  var pending = AutomationPending()
  /// 出す側の今有効な項目のリンク（取得の最新の結果）。
  var liveLinks: Set<String> = []

  static let retainedRuns = 20

  var lastRunAt: Date? { runs.first?.startedAt }

  /// 番人の数え始め。回が記録されたときだけ進む。
  var anchor: Date { lastRunAt ?? addedAt }
}

/// 受け手の「読めば取る行」。
struct AutomationPending: Equatable {
  /// 今読めば取る行の数（古さの上限を過ぎた行を除く）。
  var count = 0
  /// 数えた行のどれかが古さの上限を過ぎる最も早い時刻（過ぎたら数え直す）。上限の無い入力だけなら nil。
  var expiresAt: Date?
}

/// 項目と出来事の番号の組（読んだ位置・上流の最後の番号・読む上限）。
struct AutomationSeqs: Equatable {
  var item = 0
  var event = 0
}

/// 取得の出力 1 行の、候補に使う欄。`id` は部品の中での同一性（書かれた id）、`link` は自動化をまたぐ同一性。
struct AutomationItem: Equatable {
  let id: String
  let link: String
  let body: String
  let time: Date
}

/// 判定が出した候補。Orbe が覚えている間だけメモリに載る。リンクは覚えている候補を通じて一意。
struct AutomationProposal: Equatable, Identifiable {
  let id: Int
  /// 候補を出した判定の回。
  let runId: Int
  /// 候補を出した自動化（履歴。棚に出す自動化は `AutomationStore.shelf(of:)` が導く）。消えていれば nil。
  var automationId: Int?
  /// 出した判定の部品と、その回が動いた定義。
  let judge: AutomationPartID
  let defId: AutomationDefID
  /// 出どころの部品と行。
  let source: AutomationPartID
  let origin: AutomationRowRef
  /// 出どころの行の欄（`id` は書かれた id）。
  let item: AutomationItem
  let title: String
  let due: TaskItem.DueDate?
  /// 付け先の `Workspace.persistentId`（判定が決める）。解決できない参照は「なし」と同じに扱う。
  let workspace: UUID?
  /// 候補にした理由（判定が書いたときだけ）。
  let reason: String?
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

/// 指す行や値が読めない、覚えている候補。リンクだけを持ち、「既に候補がある」に効く。画面と判定には出さず、自動で忘れない。
struct AutomationUnreadableProposal: Equatable {
  let id: Int
  let link: String
}

extension AutomationProposal.State {
  /// ワイヤの語（open / accepted / dismissed / resolved）。
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
  /// その自動化の試走が無い。
  case trialNotFound(Int)
  /// 送った版が今の版と違う（間に定義が変わった）。
  case versionMismatch(sent: Int, current: Int)
  /// 定義を読めない自動化を動かそうとした（理由）。
  case unreadable(Int, String)
}
