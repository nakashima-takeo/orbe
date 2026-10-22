import Foundation

/// 裏で動く agent が、Orbe の MCP で自分の回の入力を読み結果を出す相手（`AutomationRunSession`）の帳面。main で使う。
///
/// 部品の 1 回が回の相手を使い捨ての札に結び付けて載せ、agent には札を持たせた Orbe の MCP を渡す。MCP の口（`run_tool`）は
/// 札の回の相手にだけ届く。回が終われば外す（以後その札は断る）。試走の走らせ役も同じ帳面を使い、試走の回の入力は写しの
/// ストアから読んだ行になる。
final class AutomationRunData {
  private var sessions: [String: AutomationRunSession] = [:]

  /// 回の相手を載せ、札を返す。
  func open(_ session: AutomationRunSession) -> String {
    let token = UUID().uuidString
    sessions[token] = session
    return token
  }

  func close(_ token: String) {
    sessions[token] = nil
  }

  /// 札の回の相手。終わった回・知らない札は nil。
  func session(_ token: String) -> AutomationRunSession? {
    sessions[token]
  }
}
