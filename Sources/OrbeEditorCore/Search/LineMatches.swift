import Foundation

/// 1 行の中の一致と、本文の写しを行ごとに探す規則。行は `\n` で割り、行末の `\r` は見せる本文（プレビュー）から外すが、
/// 一致は外す前の行に当てる。一致は重ならない順で、長さ 0 の一致は数えない。
///
/// 取り消し（`isCancelled`）は 1 行の照合の途中でも見る——利用者の正規表現は 1 行で指数時間に落ちうる（git の PCRE2 が
/// 速く返した行でも ICU は落ちうる）。取り消されたら nil。
public enum LineMatches {
  /// 行の中の一致（UTF-16）。
  public static func ranges(
    of regex: NSRegularExpression, in line: NSString, isCancelled: () -> Bool = { false }
  ) -> [NSRange]? {
    var found: [NSRange] = []
    var cancelled = false
    regex.enumerateMatches(
      in: line as String, options: [.reportProgress],
      range: NSRange(location: 0, length: line.length)
    ) { result, _, stop in
      if let range = result?.range {
        if range.length > 0 { found.append(range) }
      } else if isCancelled() {
        cancelled = true
        stop.pointee = true
      }
    }
    return cancelled ? nil : found
  }

  /// 行 `row`（0 始まり）の一致。`limit` 件まで。
  public static func matches(
    of regex: NSRegularExpression, inLine line: NSString, row: Int, limit: Int = .max,
    isCancelled: () -> Bool = { false }
  ) -> [SearchMatch]? {
    guard let found = ranges(of: regex, in: line, isCancelled: isCancelled) else { return nil }
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

  /// 本文の写しを行ごとに探す。一致と、その文書の区間（同じ順）を `limit` 件まで。取り消されたら nil。
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
    /// 今の行を探す。取り消されたら false。
    func flush() -> Bool {
      let string = line.withUnsafeBufferPointer { buffer in
        buffer.baseAddress.map { NSString(characters: $0, length: buffer.count) } ?? ""
      }
      guard
        let found = Self.matches(
          of: regex, inLine: string, row: row, limit: limit - matches.count,
          isCancelled: isCancelled)
      else { return false }
      for match in found {
        matches.append(match)
        ranges.append(
          NSRange(location: lineStart + match.column.location, length: match.column.length))
      }
      return true
    }
    for unit in text.utf16 {
      if unit == 0x0A {
        guard flush() else { return nil }
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
    if matches.count < limit, !flush() { return nil }
    return isCancelled() ? nil : (matches, ranges)
  }

  /// 見せる行の本文（行末の `\r` を外す）。
  static func displayed(_ line: NSString) -> NSString {
    guard line.length > 0, line.character(at: line.length - 1) == 0x0D else { return line }
    return line.substring(to: line.length - 1) as NSString
  }
}
