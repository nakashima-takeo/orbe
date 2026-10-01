import Foundation

/// 行のインデントの段。行頭の空白を桁で数え、`unit` 桁ごとに 1 段（スペースは 1 桁、タブは次の段の境まで）。
/// 端数は段にならない。空白だけの行は前後の非空行の浅い方まで線が続く（片側が無ければ 0）。
public enum IndentGuides {
  /// 行頭の空白が成す段の境（行の UTF-16 単位 `line` の中のオフセット）。`boundaries[k - 1]` は段 k の線が立つ文字の位置で、
  /// その直前までが k 段ぶんの空白。
  @inlinable public static func boundaries(of line: some Sequence<UInt16>, unit: Int) -> [Int] {
    guard unit > 0 else { return [] }
    var result: [Int] = []
    var column = 0
    var offset = 0
    for unitValue in line {
      switch unitValue {
      case 0x20: column += 1
      case 0x09: column += unit - column % unit
      default: return result
      }
      offset += 1
      if column % unit == 0 { result.append(offset) }
    }
    return result
  }

  /// 続いた行の並びの、各行の線の段の数。`levels` は行ごとの段（空白だけの行は nil）、`above`・`below` は並びの外で
  /// 前後に最も近い非空行の段（無ければ nil）。空白だけの行は前後の非空行の浅い方で、片側が無ければ 0。
  public static func levels(_ levels: [Int?], above: Int?, below: Int?) -> [Int] {
    var following = [Int?](repeating: nil, count: levels.count)
    var next = below
    for index in levels.indices.reversed() {
      following[index] = next
      if let level = levels[index] { next = level }
    }
    var previous = above
    return levels.indices.map { index in
      if let level = levels[index] {
        previous = level
        return level
      }
      guard let up = previous, let down = following[index] else { return 0 }
      return min(up, down)
    }
  }

  /// 空白（スペース・タブ・CR）だけの行（行の UTF-16 単位 `line`）。
  @inlinable public static func isBlank(_ line: some Sequence<UInt16>) -> Bool {
    line.allSatisfy(isBlank(unit:))
  }

  /// 空白だけの行を成す UTF-16 単位（スペース・タブ・CR）。
  @inlinable public static func isBlank(unit: UInt16) -> Bool {
    unit == 0x20 || unit == 0x09 || unit == 0x0D
  }
}
