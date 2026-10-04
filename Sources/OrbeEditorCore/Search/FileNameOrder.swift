import Foundation

/// ファイル名の比べ方（Finder・VS Code `compareFileNames` 相当: 大小とアクセントを無視し、数を数として比べる）と、それを
/// 区切りごとに使うパスの順序。エクスプローラーの並びと検索結果の順序が名前の比べ方を共有する（フォルダとファイルの
/// どちらが先かはそれぞれ）。
public enum FileNameOrder {
  /// `localizedStandardCompare`（`file2` < `file10`、`Äpfel` は a の並び）。それで同じなら（`foo1` と `foo01`、`a` と `A`）
  /// 字の並びで決める。
  public static func compare(_ a: String, _ b: String) -> ComparisonResult {
    compare(a as NSString, b as NSString)
  }

  public static func precedes(_ a: String, _ b: String) -> Bool {
    compare(a, b) == .orderedAscending
  }

  private static func compare(_ a: NSString, _ b: NSString) -> ComparisonResult {
    let result = a.localizedStandardCompare(b as String)
    guard result == .orderedSame else { return result }
    return a.compare(b as String, options: .literal)
  }

  /// パスの順序の鍵——区切りで割った名前の列。比べるたびに割らない（裏で作っておき、main では比べるだけにする）。
  public struct PathKey: Equatable, @unchecked Sendable {
    fileprivate let components: [NSString]

    public init(_ path: String) {
      components = path.split(separator: "/", omittingEmptySubsequences: false).map {
        NSString(string: String($0))
      }
    }
  }

  /// パスを区切りごとに `compare` で比べる。同じ階層ではファイルが先（片方がそこで終わるなら前）。
  public static func comparePaths(_ a: PathKey, _ b: PathKey) -> ComparisonResult {
    let one = a.components
    let other = b.components
    var index = 0
    while true {
      let endOne = index == one.count - 1
      let endOther = index == other.count - 1
      if endOne && endOther { return compare(one[index], other[index]) }
      if endOne { return .orderedAscending }
      if endOther { return .orderedDescending }
      let result = compare(one[index], other[index])
      if result != .orderedSame { return result }
      index += 1
    }
  }
}
