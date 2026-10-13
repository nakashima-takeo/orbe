import Foundation

/// 走らせるときの出力先。回の始めに `AutomationRunner` が定義の `AutomationSink` から 1 か所で写し、その回の間だけ生きる。
/// 枠（走らせ役）は段を順に回して届いた出力を渡すだけで、何を受けるか・最後の段に何を渡すか・出力をどう読み、届け、確定するかは
/// これが持つ。出力先を足すときは、これに従う型を 1 つと `AutomationSink` のケースを 1 つ足す。
///
/// 呼ばれる順は段の数によらず、取り込み（取得元がある回だけ）→ `prepare` →〔`prompt`〕→ `read` → `deliver` → `commit`。
/// 新着の無い回と中間の段が 0 行を出した回は、`prepare` から先を飛ばして `commit` に `nil` を渡す。
protocol AutomationSinkRun: AnyObject {
  /// 出力を読んだもの。
  associatedtype Output

  /// 書き換えで何をするかが変わった後の回に、前回の取得結果との差分を掛けずに全件を見直すか。
  static var reviewsAfterRework: Bool { get }

  /// 取り込み。枠の差分を経た項目のうち、この出力先が受けるものを順を保って返す。`fetched` は今回取れた全体。
  func admit(_ items: [AutomationItem], fetched: [AutomationItem]) -> [AutomationItem]
  /// 出力先へ向かう最後の入力が決まったときに 1 度呼ぶ（段があれば最後の段の入力、無ければこの出力先が読む行）。渡す行を
  /// 確かめて渡してよい行を返し、依頼文と読みに使う文脈をこの時点で取る。
  func prepare(_ rows: [String]) -> [String]
  /// 最後の段が agent のときの依頼文。
  func prompt(instruction: String, rows: [String], now: Date, timeZone: TimeZone) -> String
  /// 最後の段の出力（段が無ければ `prepare` を経た行を 1 行ずつ並べた文字列）を読む。
  func read(_ text: String) -> AutomationSinkReading<Output>
  /// 読んだ出力を届ける。終わったら失敗の理由（届いたら nil）を main で 1 度だけ返す。返る手で止める。
  func deliver(_ output: Output, completion: @escaping (String?) -> Void) -> BackgroundRunHandle
  /// 成功した回の確定。この時点の候補に当て直して、記録があれば返す。出力先へ届かなかった回の `output` は nil。
  func commit(
    _ output: Output?, into book: inout AutomationProposalBook, automations: [Automation],
    endedAt: Date
  ) -> AutomationSinkReport?
}

/// 出力先が最後の段の出力を読んだもの。`count`・`rejected` は最後の段の記録に載せる数で、何を 1 つと数えるかは出力の形を
/// 決める出力先が決める。
struct AutomationSinkReading<Output> {
  let output: Output
  let count: Int
  let rejected: AutomationRejections
}
