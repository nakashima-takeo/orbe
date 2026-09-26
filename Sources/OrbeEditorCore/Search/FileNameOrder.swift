import Foundation

/// ファイル名の並びの唯一の比べ方（VS Code `compareFileNames` / `comparePaths`）。エクスプローラーの並びと検索結果の順序が
/// これを共有し、同じ画面で並びが食い違わない。
public enum FileNameOrder {
  /// 大小無視・数を数として比べる（`file2` < `file10`）。それで同じなら（`foo1` と `foo01`、`a` と `A`）字の並びで決める。
  public static func compare(_ a: String, _ b: String) -> ComparisonResult {
    let result = a.compare(b, options: [.caseInsensitive, .numeric])
    guard result == .orderedSame, a != b else { return result }
    return a < b ? .orderedAscending : .orderedDescending
  }

  public static func precedes(_ a: String, _ b: String) -> Bool {
    compare(a, b) == .orderedAscending
  }

  /// `/` で区切ったパスを区切りごとに `compare` で比べる。同じ階層ではファイルが先（片方がそこで終わるなら前）。
  public static func comparePaths(_ a: String, _ b: String) -> ComparisonResult {
    let one = a.split(separator: "/", omittingEmptySubsequences: false)
    let other = b.split(separator: "/", omittingEmptySubsequences: false)
    var index = 0
    while true {
      let endOne = index == one.count - 1
      let endOther = index == other.count - 1
      if endOne && endOther { return compare(String(one[index]), String(other[index])) }
      if endOne { return .orderedAscending }
      if endOther { return .orderedDescending }
      let result = compare(String(one[index]), String(other[index]))
      if result != .orderedSame { return result }
      index += 1
    }
  }
}
