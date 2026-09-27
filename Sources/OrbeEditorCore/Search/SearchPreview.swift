import Foundation

/// 検索結果の 1 行に見せる切り出し（VS Code `Match.preview` に倣う）——一致の前は直前 `beforeWindow` 字だけを見て先頭の
/// 空白を削り、`maxBefore` 字を超えれば単語の境で切って `…` を前に付ける。一致とその後ろは前と合わせて `maxTotal` 字まで。
/// 長さは UTF-16。行の長さに依らず、一致の周りだけを読む。
public struct SearchPreview: Equatable, Sendable {
  public let before: String
  public let match: String
  public let after: String

  public static let maxBefore = 26
  public static let maxTotal = 250
  /// 一致の前で見る幅（VS Code は `charsPerLine / 5` に切ってから `lcut` する）。前 ＋ `…` が `maxTotal` に収まる。
  static let beforeWindow = 200

  public init(before: String, match: String, after: String) {
    self.before = before
    self.match = match
    self.after = after
  }

  /// 行の本文（行末の `\r` を除いたもの）と、その中の一致の区間から作る。
  public init(line: NSString, match range: NSRange) {
    var start = max(0, range.location - Self.beforeWindow)
    if start > 0, UTF16.isTrailSurrogate(line.character(at: start)) { start += 1 }
    let before = Self.cutBefore(
      line.substring(with: NSRange(location: start, length: range.location - start)) as NSString)
    var remaining = Self.maxTotal - (before as NSString).length
    let match = Self.prefix(of: line, from: range.location, upTo: NSMaxRange(range), remaining)
    remaining -= (match as NSString).length
    let after = Self.prefix(of: line, from: NSMaxRange(range), upTo: line.length, remaining)
    self.init(before: before, match: match, after: after)
  }

  /// `string` の [`start`, `end`) の先頭 `length` 単位（サロゲートの対は割らない）。
  private static func prefix(of string: NSString, from start: Int, upTo end: Int, _ length: Int)
    -> String
  {
    guard length > 0 else { return "" }
    var cut = min(end, start + length)
    if cut < end, UTF16.isLeadSurrogate(string.character(at: cut - 1)) { cut -= 1 }
    return string.substring(with: NSRange(location: start, length: cut - start))
  }

  /// VS Code `lcut(text, 26, '…')`: 残りが `maxBefore` 字以上になる最後の単語の境から切る。その境が無ければ末尾
  /// `maxBefore` 字（VS Code は切らずに全部を出す）。
  private static func cutBefore(_ text: NSString) -> String {
    let trimmed = trimmingLeadingWhitespace(text)
    guard trimmed.length >= maxBefore else { return trimmed as String }
    var cut = 0
    for boundary in boundaries(in: trimmed) {
      guard trimmed.length - boundary >= maxBefore else { break }
      cut = boundary
    }
    if cut == 0 {
      let start = trimmed.rangeOfComposedCharacterSequence(at: trimmed.length - maxBefore).location
      return "…" + trimmed.substring(from: start)
    }
    return "…" + (trimmingLeadingWhitespace(trimmed.substring(from: cut) as NSString) as String)
  }

  // swiftlint:disable:next force_try
  private static let boundary = try! NSRegularExpression(pattern: "\\b")

  private static func boundaries(in text: NSString) -> [Int] {
    boundary.matches(in: text as String, range: NSRange(location: 0, length: text.length))
      .map(\.range.location)
      .filter { $0 > 0 }
  }

  private static func trimmingLeadingWhitespace(_ text: NSString) -> NSString {
    var start = 0
    while start < text.length,
      let scalar = Unicode.Scalar(text.character(at: start)),
      scalar.properties.isWhitespace
    {
      start += 1
    }
    return text.substring(from: start) as NSString
  }
}
