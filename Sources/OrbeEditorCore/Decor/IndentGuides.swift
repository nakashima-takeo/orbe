import Foundation

/// 行のインデントの段。行頭の空白を桁で数え、`unit` 桁ごとに 1 段（スペースは 1 桁、タブは次の段の境まで）。
/// 端数は段にならない。空白だけの行は前後の非空行の浅い方まで線が続く（片側が無ければ 0）。
public enum IndentGuides {
  /// 行頭の空白が成す段の境（行内の UTF-16 オフセット）。`boundaries[k - 1]` は段 k の線が立つ文字の位置で、
  /// その直前までが k 段ぶんの空白。
  public static func boundaries(of line: Substring, unit: Int) -> [Int] {
    guard unit > 0 else { return [] }
    var result: [Int] = []
    var column = 0
    var offset = 0
    for unitValue in line.utf16 {
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

  /// 段の数。空白だけの行は隣の非空行の浅い方。
  public static func level(
    of line: Substring, unit: Int, previousNonBlank: Substring?, nextNonBlank: Substring?
  ) -> Int {
    guard isBlank(line) else { return boundaries(of: line, unit: unit).count }
    guard let previousNonBlank, let nextNonBlank else { return 0 }
    return min(
      boundaries(of: previousNonBlank, unit: unit).count,
      boundaries(of: nextNonBlank, unit: unit).count)
  }

  /// 空白（スペース・タブ・CR）だけの行。
  public static func isBlank(_ line: Substring) -> Bool {
    line.utf8.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
  }
}
