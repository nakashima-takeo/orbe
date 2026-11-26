import Foundation
import OrbeEditorCore

/// 縦の並びの中の位置・見えている範囲・行の右端の印を出せる行（→ `RowLayout`）。
extension RowLayout {
  /// 文書の行 `line` の中で、位置 `column`（行頭からの描く単位）を含む段（→ `WrappedLine.segment`）。
  func segment(containing column: Int, line: Int, upstream: Bool = false) -> Int {
    wrap(ofLine: line)?.segment(containing: column, upstream: upstream) ?? 0
  }

  /// 文書の行 `line` の段の下端（表示の単位。行の下の差し込みは含めない）。
  func unit(endOfLine line: Int) -> Double { unit(ofLine: line) + Double(segments(ofLine: line)) }

  // MARK: - 縦の並びの中の位置

  /// 縦の位置 `y` にある所を、縦の並びの中の位置で（段の粒度。`lineCount` 行の文書）。文書の行の中ならその行と行の中の段
  /// （範囲に収める——先頭より上は先頭の行の段 0、最後の行より下は最後の行の最後の段）、塊の中なら塊の下の文書の行（最終行の
  /// 後の塊なら行数）と、その上端からの負の段。段の境のわずかに上は境の段とみなす（`item(atY:)` と同じ許容）。
  func position(atY y: Double, lineCount: Int) -> RowPosition {
    switch item(atY: y) {
    case .line(let line, let segment):
      guard line >= 0 else { return RowPosition(line: 0) }
      let last = max(0, lineCount - 1)
      guard line <= last else {
        return RowPosition(line: last, offset: segments(ofLine: last) - 1)
      }
      return RowPosition(line: line, offset: segment)
    case .block(let index):
      let line = boundaries[index]
      let offset = (y / lineHeight + Self.slack - unit(ofLine: line)).rounded(.down)
      return RowPosition(line: line, offset: Int(offset))
    }
  }

  /// 位置の上端（表示の単位。`lineCount` 行の文書）。行は `0...lineCount` に収め、行の中の段は行の段の数に、差し込みの中を
  /// 指す負の段は、その差し込みの頭で止める。
  func unit(of position: RowPosition, lineCount: Int) -> Double {
    let line = min(max(0, position.line), lineCount)
    let top = unit(ofLine: line)
    guard position.offset < 0 else {
      let segments = line < lineCount ? segments(ofLine: line) : 1
      return top + Double(min(position.offset, segments - 1))
    }
    let inserted = (prefix[blocks(above: line)] - prefix[blocks(above: line - 1)]) / lineHeight
    return top + max(Double(position.offset), -inserted)
  }

  // MARK: - 見えている範囲

  /// 縦の位置 `y`（端を越えていれば端に収めたもの）で先頭に見えている所（表示の単位）——文書の行の中なら隠れている割合を
  /// 0…1 に収める（`lineCount` 行の文書）。
  func firstUnit(atY position: Double, lineCount: Int) -> Double {
    switch item(atY: position) {
    case .line(let raw, let rawSegment):
      let line = min(raw, max(0, lineCount - 1))
      let segment = line < raw ? segments(ofLine: line) - 1 : rawSegment
      let top = y(ofSegment: segment, line: line)
      return unit(ofLine: line) + Double(segment)
        + min(max((position - top) / lineHeight, 0), 1)
    case .block(let index):
      return unit(ofBlock: index) + (position - top(ofBlock: index)) / lineHeight
    }
  }

  // MARK: - 行の右端の印

  /// y にある、印を出せる行（`lineCount` 行の文書。出せない行なら nil）。
  func trailingMarkSpot(atY y: Double, lineCount: Int) -> TrailingMarkSpot? {
    guard hasTrailingMarks else { return nil }
    switch item(atY: y) {
    case .line(let line, _):
      guard (0..<lineCount).contains(line), let span = span(containing: line),
        spans[span].allowsTrailingMark
      else { return nil }
      return TrailingMarkSpot(
        row: .document(line), line: .document(line), top: self.y(ofLine: line))
    case .block(let index):
      guard case .lines(let lines) = contents[index], !lines.isEmpty else { return nil }
      let top = top(ofBlock: index)
      let offset = min(max(0, Int(((y - top) / lineHeight).rounded(.down))), lines.count - 1)
      guard lines[offset].allowsTrailingMark, let source = lines[offset].line else { return nil }
      return TrailingMarkSpot(
        row: .inserted(block: index, line: offset), line: .source(source),
        top: top + Double(offset) * lineHeight)
    }
  }
}

/// 行の右端の印を描く行——文書の行か、塊 `block` の中の `line` 行目の差し込んだ行。
enum TrailingMarkRow: Equatable, Sendable {
  case document(Int)
  case inserted(block: Int, line: Int)
}

/// 印を出せる行 1 つ——描く行・押下で知らせる行・行の上端（pt）。
struct TrailingMarkSpot {
  var row: TrailingMarkRow
  var line: TrailingMarkLine
  var top: Double
}
