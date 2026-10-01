import Foundation

/// 見せる空白——行頭の連続スペース・行末の連続スペース・中間の 2 個以上の連続スペース。対象は U+0020 だけ
/// （タブ・NBSP は描かない）。単語間の 1 個には何も出ない。
public enum WhitespaceRuns {
  /// 行の UTF-16 単位 `units` の中の区間（オフセット、昇順）。行末の CR は行の外として扱う。左から 1 度だけ読む。
  @inlinable public static func runs(in units: some Sequence<UInt16>) -> [Range<Int>] {
    var result: [Range<Int>] = []
    var count = 0
    var start: Int?
    /// 単語間の 1 個のうち、閉じた字が CR だったもの（その CR が行末なら行末の空白）。
    var beforeCR: Range<Int>?
    for unit in units {
      beforeCR = nil
      if unit == 0x20 {
        if start == nil { start = count }
      } else if let from = start {
        let run = from..<count
        if from == 0 || run.count >= 2 {
          result.append(run)
        } else if unit == 0x0D {
          beforeCR = run
        }
        start = nil
      }
      count += 1
    }
    if let from = start { result.append(from..<count) }
    if let run = beforeCR { result.append(run) }
    return result
  }
}
