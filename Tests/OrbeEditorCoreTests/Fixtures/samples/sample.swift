import Foundation

/// 行頭オフセットの索引。
public struct LineIndex: Equatable {
  private var starts: [Int]

  public init(text: String) {
    starts = [0]
    var offset = 0
    for unit in text.utf16 {
      offset += 1
      if unit == 0x0A { starts.append(offset) }
    }
  }

  public func point(at offset: Int) -> (row: Int, column: Int) {
    guard let row = starts.lastIndex(where: { $0 <= offset }) else { return (0, 0) }
    return (row, offset - starts[row])
  }
}
