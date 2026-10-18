import Foundation

/// 走らせ役と部品の 1 回の境目——起こし方の口と、確定の知らせ。
extension AutomationRunner {
  /// 部品の 1 回の起こし方。結果は main で 1 度だけ返し、返る手で止めたら返さない（`AutomationPartPass.start` と同じ約束）。
  typealias StartPass = (
    AutomationPassStart, @escaping (AutomationPartPass.Outcome) -> Void
  ) -> BackgroundRunHandle
}

/// 部品の 1 回の起こし方（`AutomationRunner.StartPass`）に渡すもの。
struct AutomationPassStart {
  let automationId: Int
  let node: AutomationGraph.Node
  let input: AutomationPartPass.Input
  /// 溜まりから取ったもの。入力の無い部品は nil。
  let take: AutomationInbox.Take?
  /// 走らせ役の実行の係と時計で組んだ部品の 1 回（既定の起こし方が使う）。
  let pass: AutomationPartPass
}

/// 記録した部品の 1 回（`AutomationRunner` の `recorded`）。
struct AutomationPassRecord {
  let end: AutomationPassEnd
  /// 書いた回の記録。自動化か部品がもう無く、何も書かなかったなら nil。
  let run: AutomationPartRun?
}
