import Foundation

/// エージェント hook が報告した文言と、その出所（`report_agent` の message / messageSource）。
/// 出所は文言に付随する属性なので 1 つの値にまとめる——文言の無い報告は値そのものを持たず、
/// 「文言なしの出所だけ」は表現できない。
struct AgentMessage: Equatable {
  /// ユーザーへ見せる文言（waiting の質問文・done の最終応答）。Attention 一覧が読むのはこれだけ。
  let text: String
  /// 文言の出所（`"tool"`＝このタブのエージェント自身の hook payload 由来 /
  /// `"notification"`＝CLI の通知フックが渡した文言）。上書きの可否（`controlReportAgent`）だけに
  /// 使い、表示には出ない。`"tool"` 以外（未知値・欠落）は最も弱い扱いになる。
  /// 語は orbe-report が wire へ載せる生の文字列（モジュールを共有しないので両側のテストで固定する）。
  let source: String?

  init(text: String, source: String? = nil) {
    self.text = text
    self.source = source
  }
}
