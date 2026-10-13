import Foundation

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
  /// `steps` の最後の段の `count` を出力先が数えたか。数えるのは出力先が最後の段の出力を読めた回だけで、ほかの回の最後の段は
  /// 0 行を出して止めた段か落ちた段。
  var lastStepCountedBySink: Bool
  /// 確定した回のうち出力先が記録を返した回（出力先のコマンドは走った回だけ、報告は最後の段の出力を読んだ回だけ）と、
  /// 出力先で落ちた回が持つ。失敗した回では、これがあることが出力先で落ちた印になる。
  var sink: AutomationSinkReport?
  /// 失敗した回の理由。失敗した回は前回の取得結果も出力先の状態も動かさない。
  var failure: String?
}

/// 取得元か段 1 つの記録。`count` は JSON の行として読めた数（取得元は項目として読めた数、出力先が数えた段は出力先が数えた数）、
/// `rejected` は読めなかった行。
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
  case command(AutomationCommandReport)
  /// 最後の段の出力を読んだ回はいつも持つ。`text` は報告の文で、言うことが無かった回は nil。
  case report(text: String?)
}

/// 出力先のコマンドを走らせた回の記録（落ちた回も）。
struct AutomationCommandReport: Codable, Equatable {
  var commandLine: String
  var ending: String
  /// 標準入力に渡した行の数。
  var count: Int
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
