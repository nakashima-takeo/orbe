import Foundation

/// 記録した部品の 1 回（`AutomationRunner` の `recorded`）。
struct AutomationPassRecord {
  let end: AutomationPassEnd
  /// 確定したもの。
  let recorded: AutomationRecorded

  /// 書いた回の記録。自動化か部品がもう無く、何も書かなかったなら nil。
  var run: AutomationPartRun? { recorded.run }
}
