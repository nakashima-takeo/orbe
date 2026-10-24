import Foundation

/// ノードの 1 回の記録の中身。確定（失敗の記録を含む）が、読む・確定する・当て直すときに決まった数とノードの 1 回の結果から組む。
/// 保存は時刻・契機・失敗を列に、回の履歴から数えられない残りを JSON に持ち（`AutomationRunStore`）、外の形は保存の形に英文を
/// 足したもの（`AutomationRunWire`）。手段を起こさなかった契機（取る行が 0 件）は記録しないので、いつも実行の記録を持つ。
struct AutomationNodeRun: Equatable {
  enum Trigger: String, Codable {
    case schedule
    case now
    /// 入力の行が届いた（「届いたら」のノードの回）。
    case arrival
  }

  var startedAt: Date
  var endedAt: Date
  var trigger: Trigger
  /// 取った行の数。入力の無いノードは持たない。
  var taken: Int?
  /// 読む時点で捨てた数・読む前に期限で消えた数と、ノードの持ち越しの和。
  var dropped = AutomationDrops()
  var execution: AutomationNodePass.Execution
  /// 結果を断った回だけ持つ（agent は断った呼び出しの外れた件、コマンドは外れた行）。
  var breach: AutomationRejections?
  /// 役割ごとの結果。失敗した回は持たない。
  var result: Result?
  /// この回の確定で下げた（判断待ちだった）候補の数。取得の成功した回だけ持つ。
  var withdrawn: Int?
  var failure: AutomationFailure?

  enum Result: Equatable {
    /// `fresh` は新しく有効にした行の数、`duplicates` は出来事の流れで残す期間の内に同じ id を出したので足さなかった数。
    case fetch(fresh: Int, duplicates: Int)
    case process(fresh: Int, duplicates: Int)
    /// `dismissed` は確定の当て直しで捨てた案。
    case judge(proposed: Int, resolved: Int, dismissed: [AutomationDismissal])
    /// 言うことが無かった回は nil。
    case report(text: String?)
    /// 標準入力に渡した行の数。
    case sideEffect(count: Int)
    /// 何もしなかった回は `nothing` に理由を持つ。
    case work(text: String?, nothing: String?)
  }

  var failed: Bool { failure != nil }
}

/// 捨てた行の数（理由ごと）。
struct AutomationDrops: Equatable {
  private(set) var counts: [Reason: Int] = [:]

  /// 捨てた理由。名前は回の履歴の扱いの名と同じ（`lapsed` は回の履歴に載らない）。
  enum Reason: String, CaseIterable {
    /// 古さの上限を過ぎた。
    case expired
    /// 出どころのリンクに候補がある。
    case proposed
    /// 同じリンクの、より新しい行がある。
    case sameLink
    /// 件数の上限を超えた。
    case overflow
    /// 判定のノードへ、出どころ（元になった取得の行）の無い行が届いた。
    case unsourced
    /// 同じ回の中で、同じ id の新しい行に置き換わった。
    case replaced
    /// 受け手が読む前に、残す期間を過ぎて消えた出来事（読みでは出ない。読んだ位置の進め先から数える）。
    case lapsed
  }

  var isEmpty: Bool { counts.isEmpty }

  var total: Int { counts.values.reduce(0, +) }

  mutating func add(_ reason: Reason, _ count: Int = 1) {
    guard count > 0 else { return }
    counts[reason, default: 0] += count
  }

  mutating func add(_ other: AutomationDrops) {
    for (reason, count) in other.counts { add(reason, count) }
  }
}

/// 回の記録 1 件。時刻・契機・成否は列から分かり、中身は読めなければ不明な記録になる。
struct AutomationRunRecord: Equatable {
  /// 記録の ID（`recordId`）。
  let id: Int
  let content: Content

  enum Content: Equatable {
    case known(AutomationNodeRun)
    case unknown(AutomationUnknownRun)
  }

  /// 読めた中身。不明な記録は nil。
  var run: AutomationNodeRun? {
    if case .known(let run) = content { run } else { nil }
  }

  var startedAt: Date {
    switch content {
    case .known(let run): run.startedAt
    case .unknown(let run): run.startedAt
    }
  }

  var endedAt: Date {
    switch content {
    case .known(let run): run.endedAt
    case .unknown(let run): run.endedAt
    }
  }

  var trigger: AutomationNodeRun.Trigger {
    switch content {
    case .known(let run): run.trigger
    case .unknown(let run): run.trigger
    }
  }

  var failed: Bool {
    switch content {
    case .known(let run): run.failed
    case .unknown(let run): run.failed
    }
  }
}

/// 中身の JSON を読めない回の記録（列から分かる分だけ）。
struct AutomationUnknownRun: Equatable {
  let startedAt: Date
  let endedAt: Date
  let trigger: AutomationNodeRun.Trigger
  let failed: Bool
}

/// 外れた件。件数と、最初の数件だけを残す。
struct AutomationRejections: Codable, Equatable {
  var count = 0
  var lines: [AutomationBrokenLine] = []

  static let retainedLines = 5

  init(count: Int = 0, lines: [AutomationBrokenLine] = []) {
    self.count = count
    self.lines = lines
  }

  init(_ lines: [AutomationBrokenLine]) {
    self.init(count: lines.count, lines: Array(lines.prefix(Self.retainedLines)))
  }
}
