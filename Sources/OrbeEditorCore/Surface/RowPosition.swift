import Foundation

/// 縦の並びの中の位置——文書の行 `line`（`0...行数`。行数は末尾の端）の上端から、表示の単位（行高を 1 とする）で
/// `offset` 段下。負なら `line` の前の差し込みの中で、差し込みの頭より上を指す段は頭で止まる。1 つの本文の上の位置で、同じ
/// 本文なら並びが変わっても同じ文書の行に付く。
public struct RowPosition: Hashable, Sendable {
  public let line: Int
  public let offset: Int

  public init(line: Int, offset: Int = 0) {
    self.line = line
    self.offset = offset
  }

  /// 文書の行 `line` の前の差し込みの頭（差し込みが無ければ行の上端）。
  public static func head(of line: Int) -> RowPosition {
    RowPosition(line: line, offset: .min)
  }
}
