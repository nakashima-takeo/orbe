import Foundation

/// 1 行の中の一致と、本文の写しを行ごとに探す規則。行は `\n` で割り、行末の `\r` は見せる本文（プレビュー）から外すが、
/// 一致は外す前の行に当てる。一致は重ならない順で、長さ 0 の一致は数えない。
public enum LineMatches {
  /// 行の中の一致（UTF-16）。
  public static func ranges(of regex: NSRegularExpression, in line: NSString) -> [NSRange] {
    regex.matches(in: line as String, range: NSRange(location: 0, length: line.length))
      .map(\.range)
      .filter { $0.length > 0 }
  }

  /// 行 `row`（0 始まり）の一致。`limit` 件まで。
  public static func matches(
    of regex: NSRegularExpression, inLine line: NSString, row: Int, limit: Int = .max
  ) -> [SearchMatch] {
    let found = ranges(of: regex, in: line)
    guard !found.isEmpty else { return [] }
    let shown = displayed(line)
    return found.prefix(limit).map { range in
      let start = min(range.location, shown.length)
      let end = min(NSMaxRange(range), shown.length)
      return SearchMatch(
        line: row, column: range,
        preview: SearchPreview(line: shown, match: NSRange(location: start, length: end - start)))
    }
  }

  /// 本文の写しを行ごとに探す。一致と、その文書の区間（同じ順）を `limit` 件まで。`isCancelled` が真になれば
  /// そこで止めて nil（裏の仕事の取り消し）。
  public static func search(
    _ text: TextRope, _ regex: NSRegularExpression, limit: Int,
    isCancelled: () -> Bool = { false }
  ) -> (matches: [SearchMatch], ranges: [NSRange])? {
    var matches: [SearchMatch] = []
    var ranges: [NSRange] = []
    var line = ContiguousArray<UInt16>()
    var row = 0
    var lineStart = 0
    var offset = 0
    func flush() {
      let string = line.withUnsafeBufferPointer { buffer in
        buffer.baseAddress.map { NSString(characters: $0, length: buffer.count) } ?? ""
      }
      for match in Self.matches(
        of: regex, inLine: string, row: row, limit: limit - matches.count)
      {
        matches.append(match)
        ranges.append(
          NSRange(location: lineStart + match.column.location, length: match.column.length))
      }
    }
    for unit in text.utf16 {
      if unit == 0x0A {
        flush()
        guard matches.count < limit else { break }
        if row % 256 == 0, isCancelled() { return nil }
        line.removeAll(keepingCapacity: true)
        row += 1
        lineStart = offset + 1
      } else {
        line.append(unit)
      }
      offset += 1
    }
    if matches.count < limit, offset == text.length { flush() }
    return isCancelled() ? nil : (matches, ranges)
  }

  /// 見せる行の本文（行末の `\r` を外す）。
  static func displayed(_ line: NSString) -> NSString {
    guard line.length > 0, line.character(at: line.length - 1) == 0x0D else { return line }
    return line.substring(to: line.length - 1) as NSString
  }
}
