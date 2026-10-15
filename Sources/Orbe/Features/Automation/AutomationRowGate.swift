import Foundation

/// 届いた行で動く出力先（コマンド・agent）の門。最後の段の出力を中間の段と同じ規則で読み、行が 1 行以上届いたとき、または
/// 行を作るもの（取得元か段）が無いときに開く。
struct AutomationRowGate {
  /// 行を作るもの（取得元か段）があるか。無ければ届いた行が 0 でも開く。
  let producesRows: Bool

  init(_ definition: AutomationDefinition) {
    producesRows = definition.source != nil || !definition.steps.isEmpty
  }

  /// 最後の段の出力（段が無ければ出力先が読む行）を読む。数えるのは読めた行。
  func read(_ text: String) -> AutomationSinkReading<[String]> {
    let reading = AutomationPrompts.readStep(text, step: "the last step")
    if let failure = reading.failure { return .failed(failure, rejected: reading.rejected) }
    return .output(
      reading.rows.map(\.text), count: reading.rows.count, rejected: reading.rejected)
  }

  func opens(_ rows: [String]) -> Bool {
    !rows.isEmpty || !producesRows
  }
}
