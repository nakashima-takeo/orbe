import Foundation

/// 本文からインデントの単位（1 段のスペース数）を検出する。隣り合う非空行の行頭スペース数の差のうち
/// 2 / 4 / 8 に当たるものの最頻値。同数なら小さい方、候補が無ければ 4。行頭がタブの行は差の計算に入れない
/// （タブは単位に依らず 1 段）。
public enum IndentUnit {
  public static let candidates = [2, 4, 8]
  public static let fallback = 4

  public static func detect(in text: String) -> Int {
    var counts: [Int: Int] = [:]
    var previous: Int?
    var lineStart = text.utf8.startIndex
    let utf8 = text.utf8
    var index = lineStart
    func consume(_ line: Substring) {
      guard !IndentGuides.isBlank(line) else { return }
      guard line.utf8.first != 0x09 else {
        previous = nil
        return
      }
      let spaces = line.utf8.prefix { $0 == 0x20 }.count
      if let previous, candidates.contains(abs(spaces - previous)) {
        counts[abs(spaces - previous), default: 0] += 1
      }
      previous = spaces
    }
    while index < utf8.endIndex {
      let next = utf8.index(after: index)
      if utf8[index] == 0x0A {
        consume(text[lineStart..<index])
        lineStart = next
      }
      index = next
    }
    if lineStart < utf8.endIndex { consume(text[lineStart...]) }
    return counts.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }?.key
      ?? fallback
  }
}
