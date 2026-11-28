@testable import Orbe

/// テストで 1 行の範囲を書く口（どちらも、範囲の型の作る口を通す）。
extension DiffLineRange {
  /// 側 `version` の行 `line`（0 始まり）だけの範囲。
  static func at(_ version: DiffRows.Version, _ line: Int) -> DiffLineRange {
    DiffLineRange(start: nil, end: DiffLine(version: version, line: line))
  }
}

extension GitHubLineRange {
  /// 側 `side` の行 `line`（1 始まり）だけの範囲。
  static func at(_ side: GitHubDiffSide, _ line: Int) -> GitHubLineRange {
    GitHubLineRange(start: nil, end: GitHubLine(side: side, line: line))
  }
}
