import Foundation

/// 行の中の http(s) URL。`https?://` から空白・`<` `>` `"` `` ` `` の直前までを 1 区間とし、末尾の句読点
/// （`.` `,` `;` `:` `!` `?` `'`）と、区間内に対応する開き括弧が無い末尾の `)` `]` `}` を刈る。規則は決定論的で
/// 状態を持たない（URL は行をまたがない）。
public enum LinkDetector {
  public struct Link: Equatable {
    /// 行内の UTF-16 オフセットの区間。
    public let range: NSRange
    public let url: URL

    public init(range: NSRange, url: URL) {
      self.range = range
      self.url = url
    }
  }

  private static let pattern = #/https?://[^\s<>"`]+/#

  public static func links(in line: String) -> [Link] {
    line.matches(of: pattern).compactMap { match in
      var candidate = Substring(line[match.range])
      trim(&candidate)
      guard !candidate.isEmpty,
        let url = URL(string: String(candidate), encodingInvalidCharacters: true)
      else { return nil }
      let start = line.utf16.distance(from: line.startIndex, to: candidate.startIndex)
      return Link(
        range: NSRange(location: start, length: candidate.utf16.count), url: url)
    }
  }

  private static let punctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "'"]
  private static let closers: [Character: Character] = [")": "(", "]": "[", "}": "{"]

  /// 末尾を、句読点でも対応の無い閉じ括弧でもなくなるまで刈る。
  private static func trim(_ candidate: inout Substring) {
    while let last = candidate.last {
      if punctuation.contains(last) {
        candidate.removeLast()
      } else if let opener = closers[last],
        candidate.filter({ $0 == opener }).count < candidate.filter({ $0 == last }).count
      {
        candidate.removeLast()
      } else {
        return
      }
    }
  }
}
