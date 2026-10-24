import Foundation

/// 記録したノードの 1 回（`AutomationRunner` の `recorded`）。
struct AutomationPassRecord {
  let end: AutomationPassEnd
  /// 書いた回の記録。自動化かノードがもう無く、何も書かなかったなら nil。
  let run: AutomationNodeRun?
}
