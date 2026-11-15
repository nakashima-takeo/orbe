import Foundation

/// 記録したノードの 1 回（`AutomationRunner` の `recorded`）。
struct AutomationPassRecord {
  let end: AutomationPassEnd
  /// 書いた回の記録。自動化かノードがもう無く、何も書かなかったなら nil。
  let run: AutomationNodeRun?
  /// 判定の回が確定で候補に掛けたもの（`AutomationRecorded.judged`）。
  let judged: AutomationJudged?
}
