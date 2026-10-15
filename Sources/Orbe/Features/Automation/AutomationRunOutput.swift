import Foundation

/// 走らせたもの（取得元・段・出力先のコマンド）の出力の読み取りと、失敗の文。走らせ役と出力先が同じ形で失敗を言うため、
/// ここに置く。
enum AutomationRunOutput {
  /// 走らせたものの出力。コマンドは終了コード 0 で UTF-8 の標準出力、agent は終了コード 0 で最終応答があり失敗の報告で
  /// ないこと。
  static func text(_ result: BackgroundRunResult, role: String) -> Result<String, Failure> {
    if case .command(let stdout, let stderr) = result.output {
      guard result.ending == .exited(0) else {
        return .failure(Failure(failure(role, result.ending, detail: stderr.data)))
      }
      guard let text = String(bytes: stdout.data, encoding: .utf8) else {
        return .failure(Failure("the \(role) output is not UTF-8"))
      }
      return .success(text)
    }
    guard case .agent(let reply, let stderr) = result.output, result.ending == .exited(0) else {
      var detail = Data()
      if case .agent(let reply, let stderr) = result.output {
        detail = reply.map { Data($0.text.utf8) } ?? stderr.data
      }
      return .failure(Failure(failure(role, result.ending, detail: detail)))
    }
    guard let reply else {
      return .failure(
        Failure(failure(role, result.ending, detail: stderr.data, what: "ended without a reply")))
    }
    guard !reply.isError else {
      return .failure(Failure("the \(role) agent reported an error: \(snippet(reply.text))"))
    }
    return .success(reply.text)
  }

  /// 「the <役> ended: <終わり方>: <抜粋>」。
  static func failure(
    _ role: String, _ ending: BackgroundEnding, detail: Data, what: String? = nil
  ) -> String {
    let text = snippet(String(bytes: detail, encoding: .utf8) ?? "")
    let head = "the \(role) \(what ?? "ended: \(ending.text)")"
    return text.isEmpty ? head : "\(head): \(text)"
  }

  private static func snippet(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > 500 ? String(trimmed.prefix(500)) + "…" : trimmed
  }

  struct Failure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
  }
}
