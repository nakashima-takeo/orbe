import Foundation

/// gh の呼び出しが失敗した理由。**文言は持たない**（`GitFailure` と同じく、文言への変換は面の側が持つ）。呼ぶ前に
/// 分かる可否（gh が在るか・認証情報が手元に在るか）は `GitHubAvailability` が持つ。
enum GitHubFailure: Error, Equatable {
  /// 認証が要る、または認証情報が拒まれた。
  case unauthenticated
  /// レート制限（secondary rate limit を含む）。
  case rateLimited
  /// GitHub に届かない（名前解決・接続の失敗）。
  case unreachable
  /// 1 回の呼び出しがタイムアウトした。
  case timedOut
  /// それ以外。gh のエラー文の要点をそのまま持つ。エラー文が無い（レスポンスを読めない・gh が見つからない）なら空。
  case reason(String)

  /// 0 以外の終了コードで終わった gh の 1 回の実行を分類する。材料は終了コード（4 は認証が要る）・標準エラーの字面・標準出力に載った
  /// GraphQL の `errors` の種類。gh も GitHub も「届かない」「認証が拒まれた」を機械向けの形で出さないので、字面で読む。
  static func of(status: Int32, stderr: String, stdout: Data) -> GitHubFailure {
    if status == authenticationRequiredStatus
      || ["gh auth login", "HTTP 401"].contains(where: stderr.contains)
    {
      return .unauthenticated
    }
    if graphQLErrorTypes(stdout).contains("RATE_LIMITED")
      || stderr.range(of: "rate limit", options: .caseInsensitive) != nil
    {
      return .rateLimited
    }
    let unreachable = [
      "error connecting to", "dial tcp", "TLS handshake timeout", "connection reset by peer",
    ]
    if unreachable.contains(where: stderr.contains) { return .unreachable }
    return .reason(essentialReason(stderr))
  }

  /// gh の終了コードのうち「認証が要る」（`gh help exit-codes`）。
  private static let authenticationRequiredStatus: Int32 = 4

  /// GraphQL レスポンスの `errors[].type`。レスポンスが JSON でなければ空。
  private static func graphQLErrorTypes(_ stdout: Data) -> [String] {
    (try? JSONDecoder().decode(ErrorsResponse.self, from: stdout))?.errors?.compactMap(\.type)
      ?? []
  }

  /// gh のエラー文の要点。`gh:`（`gh api`）・`GraphQL:`・`HTTP `（ほかのコマンド）で始まる行。無ければ最後の行。
  private static func essentialReason(_ stderr: String) -> String {
    let lines = stderr.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let reasons = lines.filter { line in
      ["gh:", "GraphQL:", "HTTP "].contains(where: line.hasPrefix)
    }
    return reasons.isEmpty ? lines.last ?? "" : reasons.joined(separator: "\n")
  }
}

private struct ErrorsResponse: Decodable {
  struct Error: Decodable { let type: String? }
  let errors: [Error]?
}
