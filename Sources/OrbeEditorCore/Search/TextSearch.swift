import Foundation

/// ファイル内検索の規則——needle の一致の列と、位置・選択に対する「現在／次／前」（VS Code `FindModel` と同じ起点）。
/// 状態を持たず、「現在の一致」は選択とちょうど重なる一致。
public enum TextSearch {
  /// 一致を集める上限（VS Code の MATCHES_LIMIT）。ここで打ち切り、件数は「上限+」と見せる。
  public static let limit = 19999

  /// リテラル・大小無視・重ならない一致（昇順）を `limit` 件まで。needle が空なら空。
  public static func matches(of needle: String, in text: String, limit: Int = limit) -> [NSRange] {
    guard !needle.isEmpty else { return [] }
    let haystack = text as NSString
    var result: [NSRange] = []
    var cursor = 0
    while cursor < haystack.length, result.count < limit {
      let found = haystack.range(
        of: needle, options: [.caseInsensitive, .literal],
        range: NSRange(location: cursor, length: haystack.length - cursor))
      guard found.location != NSNotFound else { break }
      result.append(found)
      cursor = NSMaxRange(found) + (found.length == 0 ? 1 : 0)
    }
    return result
  }

  /// 一致の列が上限で打ち切られたか（ちょうど上限の件数も打ち切りとして見せる——VS Code と同じ）。
  public static func isLimited(_ matches: [NSRange]) -> Bool { matches.count >= limit }

  /// 選択とちょうど重なる一致（二分探索。一致は昇順）。
  public static func exact(in matches: [NSRange], selection: NSRange) -> Int? {
    var low = 0
    var high = matches.count
    while low < high {
      let mid = (low + high) / 2
      if matches[mid].location < selection.location { low = mid + 1 } else { high = mid }
    }
    return low < matches.count && matches[low] == selection ? low : nil
  }

  /// 位置 `offset` 以降に始まる最初の一致（無ければ先頭へ循環。VS Code `matchAfterPosition`）。
  public static func first(in matches: [NSRange], from offset: Int) -> Int? {
    guard !matches.isEmpty else { return nil }
    let index = partition(matches) { $0.location >= offset }
    return index < matches.count ? index : 0
  }

  /// 位置 `offset` までに終わる最後の一致（無ければ末尾へ循環。VS Code `matchBeforePosition`）。
  public static func last(in matches: [NSRange], upTo offset: Int) -> Int? {
    guard !matches.isEmpty else { return nil }
    let index = partition(matches) { NSMaxRange($0) > offset }
    return index > 0 ? index - 1 : matches.count - 1
  }

  /// Enter の行き先——選択の終わり以降に始まる最初の一致（VS Code `moveToNextMatch`。選択が一致ならその次、キャレットが
  /// 一致の中ならその次の一致）。
  public static func next(in matches: [NSRange], from selection: NSRange) -> Int? {
    first(in: matches, from: NSMaxRange(selection))
  }

  /// ⇧Enter の行き先——選択の先頭までに終わる最後の一致（VS Code `moveToPrevMatch`）。
  public static func previous(in matches: [NSRange], from selection: NSRange) -> Int? {
    last(in: matches, upTo: selection.location)
  }

  /// 昇順で重ならない一致の列で、`isAfter` が初めて真になる位置（無ければ件数）。
  private static func partition(_ matches: [NSRange], _ isAfter: (NSRange) -> Bool) -> Int {
    var low = 0
    var high = matches.count
    while low < high {
      let mid = (low + high) / 2
      if isAfter(matches[mid]) { high = mid } else { low = mid + 1 }
    }
    return low
  }
}
