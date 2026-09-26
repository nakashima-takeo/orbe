import Foundation

/// ファイル内検索の規則——needle の一致の列と、位置・選択に対する「現在／次／前」（VS Code `FindModel` と同じ起点）。
/// 状態を持たず、「現在の一致」は選択とちょうど重なる一致。
public enum TextSearch {
  /// 一致を集める上限（VS Code の MATCHES_LIMIT）。ここで打ち切り、件数は「上限+」と見せる。
  public static let limit = 19999

  /// リテラル・大小無視・重ならない一致（昇順）を `limit` 件まで。needle が空なら空。
  public static func matches(
    of needle: String, in text: TextRope, limit: Int = limit, window: Int = scanWindow
  ) -> [NSRange] {
    guard !needle.isEmpty else { return [] }
    // 大小無視の一致は、畳み込みで字数が変わる字（合字など）があると needle より長くなりうる（1 字が最大 3 字に開く）。
    let maximumLength = (needle as NSString).length * 4
    return scan(text, maximumLength: maximumLength, limit: limit, window: window) { string, range in
      string.range(of: needle, options: [.caseInsensitive, .literal], range: range)
    }
  }

  /// 本文の写しを探す窓の大きさ（UTF-16）。
  public static let scanWindow = 65_536

  /// 本文の写しを前から窓ごとの NSString にして、重ならない一致を順に集める——全文を 1 つの文字列に写さない（窓の
  /// 大きさぶんだけを一時に持つ）。窓は `maximumLength` を越える重なりを持ち、窓の終わりの重なりより手前で始まる
  /// 一致だけを受けるので、全文を 1 つの NSString にして探したのと同じ一致を同じ順に返す。`find` は窓の中の探す区間から
  /// 最初の一致（窓の中の区間。無ければ `NSNotFound`）、`accept` はその一致を受けるか（窓は一致の前後 1 単位を含む）。
  static func scan(
    _ text: TextRope, maximumLength: Int, limit: Int, window: Int,
    find: (NSString, NSRange) -> NSRange,
    accept: (NSString, NSRange) -> Bool = { _, _ in true }
  ) -> [NSRange] {
    let overlap = maximumLength + 1
    var result: [NSRange] = []
    var cursor = 0
    while cursor < text.length, result.count < limit {
      let base = max(0, cursor - 1)
      let end = min(text.length, base + window + overlap)
      let units = text.units(in: NSRange(location: base, length: end - base))
      let string = units.withUnsafeBufferPointer { buffer in
        buffer.baseAddress.map { NSString(characters: $0, length: buffer.count) } ?? ""
      }
      let acceptable = end == text.length ? end : end - overlap
      var local = cursor - base
      while local < string.length {
        let found = find(string, NSRange(location: local, length: string.length - local))
        guard found.location != NSNotFound, base + found.location < acceptable else { break }
        if accept(string, found) {
          result.append(NSRange(location: base + found.location, length: found.length))
          guard result.count < limit else { return result }
        }
        local = max(NSMaxRange(found), found.location + 1)
      }
      guard end < text.length else { break }
      cursor = max(base + local, acceptable)
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
