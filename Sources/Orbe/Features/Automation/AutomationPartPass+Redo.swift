import Foundation

/// 決まりを外した出力の出し直し。agent の部品だけが、同じ回の中で 1 回だけ出し直す——コマンドはもう一度走らせても同じ出力に
/// なるため。
extension AutomationPartPass {
  /// 出し直しの呼び出し。1 回目と同じ CLI とモデルで、ツールは持たせない——前の出力には外の文面が入りうる。経過時間の上限は
  /// 1 回目が使った残りで、残りが無ければ（またはコマンドなら）nil。
  static func redoJob(
    _ first: BackgroundJob, _ node: AutomationGraph.Node, _ result: BackgroundRunResult,
    _ lines: [AutomationBrokenLine]
  ) -> BackgroundJob? {
    guard case .agent(let call) = first.work, case .agent(let reply?, _) = result.output else {
      return nil
    }
    let remaining = first.limits.elapsed - result.endedAt.timeIntervalSince(result.startedAt)
    guard remaining > 0 else { return nil }
    let fetch = if case .fetch = node.role { true } else { false }
    return BackgroundJob(
      work: .agent(
        BackgroundAgentCall(
          cli: call.cli, model: call.model, tools: [],
          prompt: redoPrompt(call.prompt, previous: reply.text, lines, fetch: fetch))),
      limits: BackgroundLimits(
        elapsed: remaining, idle: nil, output: first.limits.output, stderr: first.limits.stderr))
  }

  /// 出し直しの出力を 1 回目と同じ読みで読む。まだ外れていれば、出し直しの出力の行を言う失敗。
  static func redone(
    _ result: BackgroundRunResult, _ node: AutomationGraph.Node, _ input: Input,
    first: Execution, lines: [AutomationBrokenLine]
  ) -> Outcome {
    switch read(result, node, input) {
    case .failed(let reason):
      let redo = Redo(execution: execution(result), lines: [])
      return .failed(reason, first, breach: Breach(lines: lines, redo: redo))
    case .read(let output, let count, let still):
      let breach = Breach(
        lines: lines, redo: Redo(execution: execution(result, count: count), lines: still))
      guard still.isEmpty else { return .failed(broke(node, still), first, breach: breach) }
      return .succeeded(output, first, breach: breach)
    }
  }

  /// 元の依頼文・前の出力・外れた行のすべてを載せ、出力の全体を出し直させる。取得はツールが無く取り直せないので、前の出力に
  /// 無い項目を足させない。
  private static func redoPrompt(
    _ original: String, previous: String, _ lines: [AutomationBrokenLine], fetch: Bool
  ) -> String {
    let keep =
      fetch
      ? "\nDo not add items that are not in your previous output; drop a line you cannot fix."
      : ""
    return """
      Your previous output for Orbe broke the output rules of the task below. You have no tools now; fix the \
      output using only what is below.

      The task:
      \(original)

      Your previous output:
      \(previous)

      Lines that broke the rules (line numbers count every line of your previous output, blank lines included):
      \(lines.map(\.text).joined(separator: "\n"))

      Output the whole output again, corrected, following the output rules of the task exactly.\(keep)
      """
  }
}
