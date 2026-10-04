import Foundation

/// 探す問い——探す文字列と一致の規則。⌘D・⌘⇧L の続きと選択文字列の出現の強調が同じ問いで同じ一致を引くので、⌘D が次に
/// 選ぶものと強調の地が食い違わない（VS Code の `MultiCursorSession` の searchText・matchCase・wholeWord と、それを使う
/// `SelectionHighlighter`）。
public struct SearchQuestion: Equatable, Sendable {
  public var needle: String
  public var rule: MatchRule

  public init(needle: String, rule: MatchRule) {
    self.needle = needle
    self.rule = rule
  }

  /// 選択の列（主が先頭）から決まる問い。続き（⌘D・⌘⇧L が続いている間の問い）があればそれ。無ければ、どの選択も空で
  /// なく、文字列が大小を無視して同じときだけ、主の文字列を ⌘F の規則で探す（VS Code の `modelRangesContainSameText` と
  /// `MultiCursorSession.create`）。
  public static func of(
    _ selections: [NSRange], continuing: SearchQuestion?, in text: TextRope
  ) -> SearchQuestion? {
    if let continuing { return continuing }
    guard let primary = selections.first,
      selections.allSatisfy({ $0.length > 0 && NSMaxRange($0) <= text.length })
    else { return nil }
    let needle = text.substring(primary)
    if selections.count > 1 {
      let folded = needle.lowercased()
      for selection in selections.dropFirst()
      where text.substring(selection).lowercased() != folded {
        return nil
      }
    }
    return SearchQuestion(needle: needle, rule: .find)
  }
}
