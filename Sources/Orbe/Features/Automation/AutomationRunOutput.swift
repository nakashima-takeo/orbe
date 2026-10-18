import Foundation

/// 部品の手段（コマンドか agent）の出力の読み取りと、失敗の種類。役割ごとの読みが同じ形で失敗を言うため、ここに置く。
enum AutomationRunOutput {
  /// 走らせたものの出力。コマンドは終了コード 0 で UTF-8 の標準出力、agent は終了コード 0 で最終応答があり失敗の報告で
  /// ないこと。
  static func text(_ result: BackgroundRunResult) -> Result<String, AutomationFailure> {
    if case .command(let stdout, let stderr) = result.output {
      guard result.ending == .exited(0) else {
        return .failure(.ended(detail: snippet(stderr.data)))
      }
      guard let text = String(bytes: stdout.data, encoding: .utf8) else {
        return .failure(.notUTF8)
      }
      return .success(text)
    }
    guard case .agent(let reply, let stderr) = result.output, result.ending == .exited(0) else {
      var detail = Data()
      if case .agent(let reply, let stderr) = result.output {
        detail = reply.map { Data($0.text.utf8) } ?? stderr.data
      }
      return .failure(.ended(detail: snippet(detail)))
    }
    guard let reply else { return .failure(.noReply(detail: snippet(stderr.data))) }
    guard !reply.isError else { return .failure(.agentError(snippet(Data(reply.text.utf8)))) }
    return .success(reply.text)
  }

  /// 標準エラー・応答の抜粋（前後の空白を除き、500 字で切る）。
  static func snippet(_ data: Data) -> String {
    let trimmed = (String(bytes: data, encoding: .utf8) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > 500 ? String(trimmed.prefix(500)) + "…" : trimmed
  }
}
