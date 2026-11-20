import Foundation

/// ノードの手段（コマンドか agent）の終わり方の読み取り。コマンドと agent の読みが同じ形で失敗を言うため、ここに置く。
enum AutomationRunOutput {
  /// コマンドの標準出力。終了コード 0 で UTF-8 のときだけ。
  static func commandText(_ result: BackgroundRunResult) -> Result<String, AutomationFailure> {
    guard result.ending == .exited(0) else { return .failure(.ended(detail: stderr(result))) }
    guard case .command(let stdout, _) = result.output,
      let text = String(bytes: stdout.data, encoding: .utf8)
    else { return .failure(.notUTF8) }
    return .success(text)
  }

  /// agent の CLI の終わり方による失敗（終了コード 0 で最終応答があり、失敗の報告でなければ nil）。最終応答の文は結果として
  /// 読まない——結果は Orbe の MCP の道具で受ける。
  static func agentFailure(_ result: BackgroundRunResult) -> AutomationFailure? {
    guard case .agent(let reply, let stderr) = result.output, result.ending == .exited(0) else {
      var detail = Data()
      if case .agent(let reply, let stderr) = result.output {
        detail = reply.map { Data($0.text.utf8) } ?? stderr.data
      }
      return .ended(detail: snippet(detail))
    }
    guard let reply else { return .noReply(detail: snippet(stderr.data)) }
    guard !reply.isError else { return .agentError(snippet(Data(reply.text.utf8))) }
    return nil
  }

  /// コマンドの標準エラーの抜粋。
  static func stderr(_ result: BackgroundRunResult) -> String {
    guard case .command(_, let stderr) = result.output else { return "" }
    return snippet(stderr.data)
  }

  /// 標準エラー・応答の抜粋（前後の空白を除き、`excerptLength` 字で切る）。
  static func snippet(_ data: Data) -> String {
    excerpt(
      (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// 抜粋の長さ（字）。標準エラー・応答の抜粋と、報告・仕事の文の 1 行目（`summary`）を同じ長さで切る。
  static let excerptLength = 500

  /// `excerptLength` 字を超えた分を切り、切ったことを「…」で示す。
  static func excerpt(_ text: String) -> String {
    text.count > excerptLength ? String(text.prefix(excerptLength)) + "…" : text
  }
}
