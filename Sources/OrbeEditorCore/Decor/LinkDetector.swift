import Foundation

/// 行の中の http(s) URL。`http://` か `https://` から空白・`<` `>` `"` `` ` `` の直前までを 1 区間とし、末尾の句読点
/// （`.` `,` `;` `:` `!` `?` `'`）と、区間内に対応する開き括弧が無い末尾の `)` `]` `}` を刈る。規則は決定論的で
/// 状態を持たない（URL は行をまたがない）。字（書記素）を左から 1 度だけ読む走査で、どのスレッドからも呼べる（描画
/// スレッドが装備の素として引く）。
public enum LinkDetector {
  public struct Link: Equatable, Sendable {
    /// 行内の UTF-16 オフセットの区間。
    public let range: NSRange
    public let url: URL
  }

  /// 行の UTF-16 単位 `line` が URL の始まり（`://`）を含みうるか。含まなければ `links` は空——字を読む前に単位だけで
  /// 見分ける（長い行の大半は URL を持たない）。
  @inlinable public static func mayContainLinks(_ line: some Sequence<UInt16>) -> Bool {
    var matched = 0
    for unit in line {
      switch (matched, unit) {
      case (_, 0x3A): matched = 1
      case (1, 0x2F): matched = 2
      case (2, 0x2F): return true
      default: matched = 0
      }
    }
    return false
  }

  public static func links(in line: String) -> [Link] {
    var result: [Link] = []
    var index = line.startIndex
    while index < line.endIndex {
      guard let body = schemeEnd(line, at: index) else {
        index = line.index(after: index)
        continue
      }
      var end = body
      while end < line.endIndex, !isTerminator(line[end]) { end = line.index(after: end) }
      guard end > body else {
        index = line.index(after: index)
        continue
      }
      var candidate = line[index..<end]
      trim(&candidate)
      if !candidate.isEmpty,
        let url = URL(string: String(candidate), encodingInvalidCharacters: true)
      {
        let start = line.utf16.distance(from: line.startIndex, to: candidate.startIndex)
        result.append(
          Link(range: NSRange(location: start, length: candidate.utf16.count), url: url))
      }
      index = end
    }
    return result
  }

  /// `index` から `https://` か `http://` が始まれば、その直後。
  private static func schemeEnd(_ line: String, at index: String.Index) -> String.Index? {
    let rest = line[index...]
    for scheme in ["https://", "http://"] where rest.hasPrefix(scheme) {
      return line.index(index, offsetBy: scheme.count)
    }
    return nil
  }

  private static func isTerminator(_ character: Character) -> Bool {
    character.isWhitespace || character == "<" || character == ">" || character == "\""
      || character == "`"
  }

  private static let punctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "'"]
  private static let closers: [Character: Character] = [")": "(", "]": "[", "}": "{"]

  /// 末尾を、句読点でも対応の無い閉じ括弧でもなくなるまで刈る。
  private static func trim(_ candidate: inout Substring) {
    var unmatched: [Character: Int] = [:]
    for (closer, opener) in closers {
      unmatched[closer] = candidate.reduce(0) { $0 + ($1 == closer ? 1 : $1 == opener ? -1 : 0) }
    }
    while let last = candidate.last {
      if punctuation.contains(last) {
        candidate.removeLast()
      } else if let count = unmatched[last], count > 0 {
        unmatched[last] = count - 1
        candidate.removeLast()
      } else {
        return
      }
    }
  }
}
