import Foundation

/// 本文からインデントの単位（1 段のスペース数）を検出する。隣り合う非空行の行頭スペース数の差のうち
/// 2 / 4 / 8 に当たるものの最頻値。同数なら小さい方、候補が無ければ 4。行頭がタブの行は差の計算に入れない
/// （タブは単位に依らず 1 段）。空白（スペース・タブ・CR）だけの行は数えない。
public enum IndentUnit {
  private static let candidates = [2, 4, 8]
  public static let fallback = 4

  /// 本文の UTF-16 単位を先頭から 1 度だけ読む。
  public static func detect(in units: some Sequence<UInt16>) -> Int {
    var counts: [Int: Int] = [:]
    var previous: Int?
    var spaces = 0
    var leading = true
    var startsWithTab = false
    var blank = true
    var length = 0
    func endLine() {
      defer {
        spaces = 0
        leading = true
        startsWithTab = false
        blank = true
        length = 0
      }
      guard !blank else { return }
      guard !startsWithTab else {
        previous = nil
        return
      }
      if let previous, candidates.contains(abs(spaces - previous)) {
        counts[abs(spaces - previous), default: 0] += 1
      }
      previous = spaces
    }
    for unit in units {
      guard unit != 0x0A else {
        endLine()
        continue
      }
      if length == 0, unit == 0x09 { startsWithTab = true }
      length += 1
      if unit != 0x20 && unit != 0x09 && unit != 0x0D { blank = false }
      if leading {
        if unit == 0x20 { spaces += 1 } else { leading = false }
      }
    }
    if length > 0 { endLine() }
    return counts.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }?.key
      ?? fallback
  }
}
