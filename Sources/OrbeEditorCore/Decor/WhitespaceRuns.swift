import Foundation

/// 見せる空白——行頭の連続スペース・行末の連続スペース・中間の 2 個以上の連続スペース。対象は U+0020 だけ
/// （タブ・NBSP は描かない）。単語間の 1 個には何も出ない。
public enum WhitespaceRuns {
  /// 行内の UTF-16 オフセットの区間（昇順）。行末の CR は行の外として扱う。
  public static func runs(in line: Substring) -> [Range<Int>] {
    let units = Array(line.utf16)
    let end = units.last == 0x0D ? units.count - 1 : units.count
    var result: [Range<Int>] = []
    var index = 0
    while index < end {
      guard units[index] == 0x20 else {
        index += 1
        continue
      }
      var stop = index
      while stop < end, units[stop] == 0x20 { stop += 1 }
      if index == 0 || stop == end || stop - index >= 2 { result.append(index..<stop) }
      index = stop
    }
    return result
  }
}
