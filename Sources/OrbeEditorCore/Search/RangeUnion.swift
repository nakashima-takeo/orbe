import Foundation

/// 昇順で重ならない区間の列の和（昇順。重なる区間は 1 つにまとめる）。面の「一致の地」の口は 1 つなので、⌘F と
/// プロジェクト検索の 2 つの出どころを和にして押す。
public enum RangeUnion {
  public static func union(_ a: [NSRange], _ b: [NSRange]) -> [NSRange] {
    guard !a.isEmpty else { return b }
    guard !b.isEmpty else { return a }
    var result: [NSRange] = []
    result.reserveCapacity(a.count + b.count)
    var i = 0
    var j = 0
    while i < a.count || j < b.count {
      let next: NSRange
      if j >= b.count || (i < a.count && a[i].location <= b[j].location) {
        next = a[i]
        i += 1
      } else {
        next = b[j]
        j += 1
      }
      if let last = result.last, next.location < NSMaxRange(last) {
        result[result.count - 1] = NSUnionRange(last, next)
      } else {
        result.append(next)
      }
    }
    return result
  }
}
