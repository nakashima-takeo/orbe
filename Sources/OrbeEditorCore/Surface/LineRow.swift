import Foundation

/// 文書の行 `line` の前の差し込みの中で、差し込んだ行だけを数えた段 `offset`（負。0 なら文書の行そのもの）。絵の差し込みと
/// 空きの高さを数えないので、それらの高さが変わっても同じ差し込んだ行を指す——表示の単位の段（`RowPosition`）とは別の座標。
public struct LineRow: Hashable, Sendable {
  public let line: Int
  public let offset: Int

  public init(line: Int, offset: Int = 0) {
    self.line = line
    self.offset = offset
  }
}
