import Foundation

/// プロジェクト検索の問い——検索語と 3 つの切替。意味の規則（素の文字列のエスケープ・単語単位の境界・大小無視）はここ
/// 1 か所にあり、同じ問いを開いている文書を探す ICU の式と、ディスクを探す git の PCRE2 の式の 2 つに組み立てる。
/// 2 つのエンジンの意味は完全には揃わない（大小無視の畳み込み・単語の字の範囲。docs/spec/editor/search.md）。
public struct SearchQuery: Equatable, Sendable, Codable {
  public var pattern: String
  public var matchCase: Bool
  public var wholeWord: Bool
  public var isRegex: Bool

  public init(
    pattern: String = "", matchCase: Bool = false, wholeWord: Bool = false, isRegex: Bool = false
  ) {
    self.pattern = pattern
    self.matchCase = matchCase
    self.wholeWord = wholeWord
    self.isRegex = isRegex
  }

  /// 欠けた項目・読めない項目は既定で埋める（永続の 1 項目で問い全体を失わない）。
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    pattern = (try? c.decodeIfPresent(String.self, forKey: .pattern)) ?? ""
    matchCase = (try? c.decodeIfPresent(Bool.self, forKey: .matchCase)) ?? false
    wholeWord = (try? c.decodeIfPresent(Bool.self, forKey: .wholeWord)) ?? false
    isRegex = (try? c.decodeIfPresent(Bool.self, forKey: .isRegex)) ?? false
  }

  /// 空の検索語は「検索しない」。
  public var isEmpty: Bool { pattern.isEmpty }

  /// 組み立てられない問い（ICU が断った正規表現。ICU は断った理由を返さない）。
  public struct Invalid: Error, Equatable {}

  /// 2 つの式に組み立てる。ICU で組めなければ `Invalid`。
  public func compiled() throws -> CompiledSearchQuery {
    var source = isRegex ? pattern : Self.escaped(pattern)
    if wholeWord {
      if let first = pattern.unicodeScalars.first, Self.isWordScalar(first) {
        source = "\\b" + source
      }
      if let last = pattern.unicodeScalars.last, Self.isWordScalar(last) { source += "\\b" }
    }
    if !matchCase { source = "(?i)" + source }
    guard let regex = try? NSRegularExpression(pattern: source) else { throw Invalid() }
    return CompiledSearchQuery(regex: regex, pcre: "(*UCP)(*ANYCRLF)" + source)
  }

  /// 正規表現の特殊文字だけを `\` で字どおりにする（ICU と PCRE2 のどちらでも「英数字以外の前の `\` は字そのもの」）。
  public static func escaped(_ literal: String) -> String {
    var out = ""
    for scalar in literal.unicodeScalars {
      if specials.contains(scalar) { out.append("\\") }
      out.unicodeScalars.append(scalar)
    }
    return out
  }

  private static let specials = Set("\\^$.|?*+()[]{}".unicodeScalars)

  /// 検索語の先頭・末尾に単語の境界を足すかの判定——ASCII の英数字と `_` だけ（VS Code `createRegExp` は JS の ASCII の
  /// `\B` で判定する）。足した境界そのものは両エンジンとも Unicode で判定する。
  static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar == "_" || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
      || ("0"..."9").contains(scalar)
  }
}

/// 組み立てた問い。`regex` は開いている文書と行の中の位置を取る ICU の式、`pcre` は git grep `-P` に渡す式（`\w` `\b` を
/// Unicode に固定する `(*UCP)` と、`$` を行末の `\r` の前でも当てる `(*ANYCRLF)` 付き——どちらも ICU の既定に揃える）。
public struct CompiledSearchQuery: Sendable {
  public let regex: NSRegularExpression
  public let pcre: String
}
