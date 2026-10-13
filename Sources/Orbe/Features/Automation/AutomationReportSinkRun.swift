import Foundation

/// 報告の 1 回。最後の段の出力を JSON の行としては読まず、文章のまま回の結果として残す。届け先も状態も持たない。
final class AutomationReportSinkRun: AutomationSinkRun {
  /// 最後の段の出力を読んだもの。
  struct Output {
    /// 報告の文。言うことが無かった回は nil。
    let text: String?
  }

  /// 見直すと、指示文を直しただけで今の集合の全件が報告に載り直す。報告は前回から何があったかを言う役。
  static let reviewsAfterRework = false

  /// 残す報告の上限（字）。回の記録は 20 回残る。
  static let limit = 2000

  /// 要件。文章を書くのは最後の段の役なので、段が 1 つ以上要る。取得元は任意。
  static func check(_ definition: AutomationDefinition) throws(AutomationError) {
    guard !definition.steps.isEmpty else {
      throw .invalid("sink: report needs at least one step")
    }
  }

  func admit(_ items: [AutomationItem], fetched: [AutomationItem]) -> [AutomationItem] { items }

  func prepare(_ rows: [String]) -> [String] { rows }

  func prompt(instruction: String, rows: [String], now: Date, timeZone: TimeZone) -> String {
    AutomationPrompts.report(instruction: instruction, rows: rows, now: now, timeZone: timeZone)
  }

  /// 前後の空白を除き、上限を超えれば切る。最後の段の記録に載せる数は、報告があれば 1。
  func read(_ text: String) -> AutomationSinkReading<Output> {
    let output = Output(text: Self.kept(text))
    return .output(output, count: output.text == nil ? 0 : 1, rejected: AutomationRejections())
  }

  /// 残す報告の文。前後の空白を除いて上限で切り、空なら nil。
  static func kept(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
  }

  func deliver(_ output: Output, completion: @escaping (AutomationSinkFailure?) -> Void)
    -> BackgroundRunHandle
  {
    completion(nil)
    return BackgroundRunHandle {}
  }

  /// 最後の段の出力を読んだ回は、報告が無くても記録を返す——記録だけで「報告なし」と「途中ですべて除外」を言い分けるため。
  func commit(
    _ output: Output?, into book: inout AutomationProposalBook, automations: [Automation],
    endedAt: Date
  ) -> AutomationSinkReport? {
    output.map { .report(text: $0.text) }
  }
}
