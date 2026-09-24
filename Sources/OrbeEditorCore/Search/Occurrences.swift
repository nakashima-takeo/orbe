import Foundation

/// 出現の強調の規則——選択文字列の他の出現（VS Code `SelectionHighlighter`）と、キャレットの語の出現（VS Code
/// `WordHighlighter` の textual provider）。語の定義は VS Code の既定の語（区切り文字と空白で切る）で、全言語共通。
public enum Occurrences {
  /// 集める上限（VS Code の LIMIT_FIND_COUNT）。
  public static let limit = 999
  /// 選択文字列の出現を出す選択の長さの上限（UTF-16。VS Code `selectionHighlightMaxLength`）。
  public static let maxSelectionLength = 200
  /// VS Code `USUAL_WORD_SEPARATORS`。
  private static let separators = Set(separatorCharacters.utf16)
  private static let separatorCharacters = "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?"

  /// 選択文字列の他の出現（大小無視・語の境界なし）。選択自身と、選択より前に始まって選択と交差する一致は除く。
  /// 選択が空・複数行・空白だけ・長すぎるときと、検索バーがその文字列を探しているとき（`findNeedle` と大小無視で同じ、
  /// または `findFieldFocused` で検索語が空でない）は出さない。
  public static func selectionOccurrences(
    of selection: NSRange, in text: String, findNeedle: String?, findFieldFocused: Bool
  ) -> [NSRange] {
    let string = text as NSString
    guard selection.length > 0, selection.length <= maxSelectionLength,
      NSMaxRange(selection) <= string.length
    else { return [] }
    let needle = string.substring(with: selection)
    guard !needle.contains(where: \.isNewline), !needle.allSatisfy({ $0 == " " || $0 == "\t" })
    else { return [] }
    if let findNeedle, !findNeedle.isEmpty {
      if findFieldFocused || findNeedle.lowercased() == needle.lowercased() { return [] }
    }
    return TextSearch.matches(of: needle, in: text, limit: limit).filter { match in
      if match == selection { return false }
      return
        !(match.location < selection.location && NSIntersectionRange(match, selection).length > 0)
    }
  }

  /// 語を探す行の長さの上限（VS Code `getWordAtText` の maxLen）。これより長い行はキャレットの前後半分ずつの窓で探す。
  public static let maxLineLength = 1000

  /// 語を探す窓——行（`line`、改行を除く）が長ければキャレットの前後 `maxLineLength / 2` ずつ（VS Code と同じく、窓の
  /// 端にかかる語は窓で切れる）。
  public static func wordWindow(caret: Int, line: NSRange) -> NSRange {
    guard line.length > maxLineLength else { return line }
    let start = max(line.location, caret - maxLineLength / 2)
    let end = min(NSMaxRange(line), caret + maxLineLength / 2)
    return NSRange(location: start, length: max(0, end - start))
  }

  /// キャレット（または 1 行の選択）の語。選択の先頭の位置の語で、選択はその語の内側かちょうどその語であること。
  /// 語は窓の先頭から見て、選択の先頭を含む（端に接するものも含む）最初の語（VS Code `getWordAtText`）。`text` は
  /// 窓（`wordWindow`）の本文、`textStart` はその始まりのオフセット。
  public static func word(at selection: NSRange, text: String, textStart: Int) -> NSRange? {
    let length = (text as NSString).length
    let position = selection.location - textStart
    guard position >= 0, position <= length, NSMaxRange(selection) - textStart <= length else {
      return nil
    }
    var found: NSRange?
    wordPattern.enumerateMatches(in: text, range: NSRange(location: 0, length: length)) {
      match, _, stop in
      guard let range = match?.range, range.location <= position else {
        stop.pointee = true
        return
      }
      guard NSMaxRange(range) >= position else { return }
      stop.pointee = true
      guard NSMaxRange(range) >= NSMaxRange(selection) - textStart else { return }
      found = NSRange(location: textStart + range.location, length: range.length)
    }
    return found
  }

  /// 語 `word`（本文の区間）の全出現（大小区別・語の境界つき・自分を含む）。
  public static func wordOccurrences(of word: NSRange, in text: String) -> [NSRange] {
    let string = text as NSString
    guard word.length > 0, NSMaxRange(word) <= string.length else { return [] }
    let needle = string.substring(with: word)
    var result: [NSRange] = []
    var cursor = 0
    while cursor < string.length, result.count < limit {
      let found = string.range(
        of: needle, options: [.literal],
        range: NSRange(location: cursor, length: string.length - cursor))
      guard found.location != NSNotFound else { break }
      if isWordBoundary(before: found, in: string), isWordBoundary(after: found, in: string) {
        result.append(found)
      }
      cursor = NSMaxRange(found)
    }
    return result
  }

  /// VS Code の既定の語の正規表現（`DEFAULT_WORD_REGEXP`）。JS の `\d`・`\w` は ASCII だけに当たる（u フラグ無し）ので、
  /// Unicode 全体に当たる ICU の `\d`・`\w` は使わず ASCII の文字クラスで書く。
  private static let wordPattern: NSRegularExpression = {
    let escaped = separatorCharacters.map { "\\\($0)" }.joined()
    // swiftlint:disable:next force_try
    return try! NSRegularExpression(
      pattern: "(-?[0-9]*\\.[0-9][A-Za-z0-9_]*)|([^\(escaped)\\s]+)")
  }()

  /// 区切り（区切り文字・空白・改行）か。
  private static func isSeparator(_ unit: UInt16) -> Bool {
    separators.contains(unit) || unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
  }

  private static func isWordBoundary(before range: NSRange, in string: NSString) -> Bool {
    range.location == 0 || isSeparator(string.character(at: range.location - 1))
      || isSeparator(string.character(at: range.location))
  }

  private static func isWordBoundary(after range: NSRange, in string: NSString) -> Bool {
    NSMaxRange(range) == string.length || isSeparator(string.character(at: NSMaxRange(range)))
      || isSeparator(string.character(at: NSMaxRange(range) - 1))
  }
}
