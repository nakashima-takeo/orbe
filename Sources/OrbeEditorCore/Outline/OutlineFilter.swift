import Foundation

/// 絞り込みの結果。一致したシンボルとその祖先（一致しなくても残す。VS Code の tree の絞り込みと同じ）を位置順に並べる。
public struct OutlineFilterResult: Sendable {
  public let pattern: String
  /// 絞り込んだ結果。
  public let token: OutlineToken
  /// 残るシンボルの番号（昇順）。
  public let visible: [Int]
  /// 一致したシンボルの番号（昇順。祖先として残っただけのものは含まない）。
  public let matched: [Int]
  /// 一致したシンボルの番号 → 名前の中で一致した字の区間（UTF-16、昇順）。
  public let matches: [Int: [Range<Int>]]
}

/// アウトライン 1 つに照合をかける（アウトラインの裏の仕事の中だけで使う）。照合は VS Code の tree の絞り込みと同じ
/// （`FuzzyScorer`）で、点数では並べ替えない。
struct OutlineFilter {
  let token: OutlineToken
  private let names: [String]
  private let parents: [Int?]

  init(_ outline: DocumentOutline) {
    token = outline.token
    names = outline.symbols.map(\.name)
    parents = outline.symbols.map(\.parent)
  }

  func apply(_ pattern: String) -> OutlineFilterResult {
    let scorer = FuzzyScorer(pattern: pattern)
    var keep = [Bool](repeating: false, count: names.count)
    var matches: [Int: [Range<Int>]] = [:]
    var matched: [Int] = []
    for (index, name) in names.enumerated() {
      guard let ranges = scorer.matches(name) else { continue }
      matches[index] = ranges
      matched.append(index)
      var node: Int? = index
      while let current = node, !keep[current] {
        keep[current] = true
        node = parents[current]
      }
    }
    return OutlineFilterResult(
      pattern: pattern, token: token, visible: keep.indices.filter { keep[$0] }, matched: matched,
      matches: matches)
  }
}
