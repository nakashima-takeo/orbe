import Foundation

/// ファイル内検索の規則——needle の一致の列と、選択に対する「現在／次／前」。状態を持たず、「現在の一致」は
/// 常に選択の関数（選択が一致 i と一致すれば i、そうでなければ選択の先頭以降で最初の一致）。
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

  /// 選択が一致 i と一致すれば i。そうでなければ選択の先頭以降で最初の一致（無ければ先頭へ循環）。
  public static func current(in matches: [NSRange], from selection: NSRange) -> Int? {
    guard !matches.isEmpty else { return nil }
    if let exact = matches.firstIndex(of: selection) { return exact }
    return matches.firstIndex { $0.location >= selection.location } ?? 0
  }

  /// 選択が一致 i と一致すれば i + 1（末尾で先頭へ循環）、そうでなければ `current`。
  public static func next(in matches: [NSRange], from selection: NSRange) -> Int? {
    guard !matches.isEmpty else { return nil }
    if let exact = matches.firstIndex(of: selection) { return (exact + 1) % matches.count }
    return current(in: matches, from: selection)
  }

  /// 選択が一致 i と一致すれば i − 1（先頭で末尾へ循環）、そうでなければ選択の先頭より前で最後の一致
  /// （無ければ末尾へ循環）。
  public static func previous(in matches: [NSRange], from selection: NSRange) -> Int? {
    guard !matches.isEmpty else { return nil }
    if let exact = matches.firstIndex(of: selection) {
      return (exact + matches.count - 1) % matches.count
    }
    return matches.lastIndex { $0.location < selection.location } ?? matches.count - 1
  }
}
