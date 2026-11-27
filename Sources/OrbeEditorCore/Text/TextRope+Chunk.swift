/// 本文の塊と、塊ごとに束ねる要約。
extension TextRope {
  public struct Summary: TreeSummary {
    public var utf16: Int
    public var utf8: Int
    public var newlines: Int

    public static let zero = Summary(utf16: 0, utf8: 0, newlines: 0)

    public static func + (lhs: Summary, rhs: Summary) -> Summary {
      Summary(
        utf16: lhs.utf16 + rhs.utf16, utf8: lhs.utf8 + rhs.utf8,
        newlines: lhs.newlines + rhs.newlines)
    }
  }

  struct Chunk: TreeElement {
    let units: ContiguousArray<UInt16>
    /// 塊の中の `\n` の位置（昇順）。行とオフセットの変換で塊を読み直さない。
    let newlines: ContiguousArray<UInt16>
    let summary: Summary

    init(_ units: ContiguousArray<UInt16>) {
      self.units = units
      var newlines = ContiguousArray<UInt16>()
      var utf8 = 0
      for (position, unit) in units.enumerated() {
        if unit == 0x0A { newlines.append(UInt16(position)) }
        utf8 += unit < 0x80 ? 1 : unit < 0x800 || UTF16.isSurrogate(unit) ? 2 : 3
      }
      self.newlines = newlines
      summary = Summary(utf16: units.count, utf8: utf8, newlines: newlines.count)
    }

    /// 塊の中で `local` より前にある `\n` の数。
    func newlines(before local: Int) -> Int {
      var low = 0
      var high = newlines.count
      while low < high {
        let mid = (low + high) / 2
        if Int(newlines[mid]) < local { low = mid + 1 } else { high = mid }
      }
      return low
    }
  }
}
