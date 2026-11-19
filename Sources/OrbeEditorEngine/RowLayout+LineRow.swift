import Foundation
import OrbeEditorCore

/// 差し込んだ行だけを数えた段——行の前の塊の中の位置を、絵の差し込みと空きの高さを数えずに表す（絵の差し込みの高さが
/// 変わっても、同じ差し込んだ行を指す）。
extension RowLayout {
  /// 位置 `position` を、行の前の塊のうち差し込んだ行だけを数えた段に直す（絵の差し込みと空きの高さを数えない）。位置が
  /// 絵の差し込みか空きの中なら、その下の差し込んだ行（無ければ文書の行）の頭。文書の行の中（段が 0 以上）ならそのまま。
  func lineRow(of position: RowPosition) -> RowPosition {
    guard position.offset < 0 else { return position }
    let range = blocks(above: position.line - 1)..<blocks(above: position.line)
    let total = (prefix[range.upperBound] - prefix[range.lowerBound]) / lineHeight
    let lines = insertedLines(in: range)
    // 高さの和は別々の浮動小数の和なので、行の頭を少し越えた所とみなして、端数で上の行に化けないようにする。
    let fromTop = max(0, total + max(Double(position.offset), -total)) + Self.slack
    var (top, before) = (0.0, 0)
    for index in range {
      if case .lines(let run) = contents[index] {
        if fromTop < top + Double(run.count) {
          return RowPosition(
            line: position.line, offset: before + Int(fromTop - top) - lines)
        }
        top += Double(run.count)
        before += run.count
      } else {
        let height = heights[index] / lineHeight
        if fromTop < top + height {
          return RowPosition(line: position.line, offset: before - lines)
        }
        top += height
      }
    }
    return RowPosition(line: position.line)
  }

  /// 差し込んだ行だけを数えた段 `row` の位置（`lineRow(of:)` の逆）。段が塊の差し込んだ行の数を超えれば、塊の頭。
  func position(ofLineRow row: RowPosition) -> RowPosition {
    guard row.offset < 0 else { return row }
    let range = blocks(above: row.line - 1)..<blocks(above: row.line)
    let total = (prefix[range.upperBound] - prefix[range.lowerBound]) / lineHeight
    let target = max(0, insertedLines(in: range) + max(row.offset, -insertedLines(in: range)))
    var (top, before) = (0.0, 0)
    for index in range {
      if case .lines(let run) = contents[index] {
        if target < before + run.count {
          // 段は行の上端からの整数の表示の単位なので、その差し込んだ行の中に入る最も上の段にする。
          let offset = (top + Double(target - before) - total - Self.slack).rounded(.up)
          return RowPosition(line: row.line, offset: Int(offset))
        }
        top += Double(run.count)
        before += run.count
      } else {
        top += heights[index] / lineHeight
      }
    }
    return RowPosition(line: row.line)
  }

  /// 塊 `range` の差し込んだ行の数。
  private func insertedLines(in range: Range<Int>) -> Int {
    range.reduce(0) { count, index in
      if case .lines(let run) = contents[index] { return count + run.count }
      return count
    }
  }
}
