import Foundation

/// コマンドの部品の結果の読み。標準出力を、agent の道具と同じ決まり（`AutomationOutputs`）で確かめる。何も無い回は空の
/// 出力、失敗は 0 以外の終了コード。
extension AutomationPartPass {
  static func commandEnded(_ result: BackgroundRunResult, _ input: Input) -> Outcome {
    if case .sideEffect(let rows, _) = input {
      guard result.ending == .exited(0) else {
        return .failed(
          .ended(detail: AutomationRunOutput.stderr(result)), execution(result), breach: nil)
      }
      return .succeeded(.sideEffect, execution(result, count: rows.count), breach: nil)
    }
    let text: String
    switch AutomationRunOutput.commandText(result) {
    case .failure(let failure): return .failed(failure, execution(result), breach: nil)
    case .success(let stdout): text = stdout
    }
    var outputs = AutomationOutputs(input)
    switch input {
    case .report:
      outputs.putReport(text)
    case .fetch, .process, .judge:
      let broken = outputs.put(text)
      guard broken.isEmpty else {
        return .failed(.brokeRules, execution(result), breach: AutomationRejections(broken))
      }
    case .work, .sideEffect:
      preconditionFailure("a work part is an agent; a side effect is read above")
    }
    return .succeeded(
      outputs.output(nothing: nil), execution(result, count: outputs.count), breach: nil)
  }
}
