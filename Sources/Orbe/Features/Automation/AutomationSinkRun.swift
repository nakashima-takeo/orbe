import Foundation

/// 走らせるときの出力先。回の始めに `AutomationRunner` が定義の `AutomationSink` から 1 か所で写し、その回の間だけ生きる。
/// 枠（走らせ役）は段を順に回すだけで、何を受けるか・最後の段に何を渡すか・最後の段の出力をどう読み、届け、確定するかは
/// これが持つ。出力先を足すときは、これに従う型を 1 つと `AutomationSink` のケースを 1 つ足す。
protocol AutomationSinkRun: AnyObject {
  /// 最後の段の出力を読んだもの。
  associatedtype Output

  /// 取り込み。枠の差分を経た項目のうち、この出力先が受けるものを順を保って返す。`fetched` は今回取れた全体。
  func admit(_ items: [AutomationItem], fetched: [AutomationItem]) -> [AutomationItem]
  /// 最後の段を始めるときに呼ぶ。渡す行を確かめて渡してよい行を返し、依頼文と読みに使う文脈をこの時点で取る。
  func prepareLastStep(_ rows: [String]) -> [String]
  /// 最後の段が agent のときの依頼文。
  func prompt(instruction: String, rows: [String], now: Date, timeZone: TimeZone) -> String
  /// 最後の段の出力の行を読む。読めない行は捨てて理由を残し、回は失敗にしない。
  func read(_ rows: [AutomationRow]) -> Output
  /// 読んだ出力を届ける。終わったら失敗の理由（届いたら nil）を main で 1 度だけ返す。返る手で止める。
  func deliver(_ output: Output, completion: @escaping (String?) -> Void) -> BackgroundRunHandle
  /// 成功した回の確定。この時点の候補に当て直して記録を返す。最後の段まで行かなかった回の `output` は nil。
  func commit(
    _ output: Output?, into book: inout AutomationProposalBook, automations: [Automation],
    endedAt: Date
  ) -> AutomationSinkReport
}
