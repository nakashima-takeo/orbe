import Foundation

/// 出現の強調の規則——選択文字列の他の出現（VS Code `SelectionHighlighter`）と、キャレットの語の出現（VS Code
/// `WordHighlighter` の textual provider）。キャレットの語を拾うのは VS Code の既定の語（区切り文字と空白で切る）で、全言語
/// 共通。出現の一致は一致の規則（`MatchRule`）から引く。
public enum Occurrences {
  /// 集める上限（VS Code の LIMIT_FIND_COUNT）。
  public static let limit = 999
  /// 選択文字列の出現を出す文字列の長さの上限（UTF-16。VS Code `selectionHighlightMaxLength`）。
  public static let maxSelectionLength = 200

  /// 選択文字列の他の出現——選択の列（`selections`）から決まる問い `question` の一致のうち、どの選択とも同じ区間でなく、
  /// 選択より前に始まって空でない選択に重なるものでもない出現（VS Code `SelectionHighlighter` の除き方）。探す文字列が
  /// 複数行・空白だけ・長すぎるときと、検索バーがその文字列を探しているとき（⌘F の規則の問いで `findNeedle` と大小無視で
  /// 同じ、または `findFieldFocused` で検索語が空でない）は出さない。
  public static func selectionOccurrences(
    of question: SearchQuestion, selections: [NSRange], in text: TextRope, findNeedle: String?,
    findFieldFocused: Bool, window: Int = TextSearch.scanWindow
  ) -> [NSRange] {
    let needle = question.needle
    guard !needle.isEmpty, (needle as NSString).length <= maxSelectionLength,
      !needle.contains(where: \.isNewline), !needle.allSatisfy({ $0 == " " || $0 == "\t" })
    else { return [] }
    if let findNeedle, !findNeedle.isEmpty {
      if findFieldFocused { return [] }
      if question.rule == .find, findNeedle.lowercased() == needle.lowercased() { return [] }
    }
    let matches = TextSearch.matches(
      of: needle, in: text, rule: question.rule, limit: limit, window: window)
    let sorted = selections.sorted {
      $0.location != $1.location ? $0.location < $1.location : $0.length < $1.length
    }
    var result: [NSRange] = []
    var j = 0
    for match in matches {
      while j < sorted.count, precedes(sorted[j], match) { j += 1 }
      if j < sorted.count {
        let selection = sorted[j]
        if selection == match { continue }
        if selection.length > 0, NSIntersectionRange(match, selection).length > 0 { continue }
      }
      result.append(match)
    }
    return result
  }

  /// 区間の並び（始まり、同じなら終わりの順。VS Code `Range.compareRangesUsingStarts`）で `a` が `b` より前か。
  private static func precedes(_ a: NSRange, _ b: NSRange) -> Bool {
    a.location != b.location ? a.location < b.location : NSMaxRange(a) < NSMaxRange(b)
  }

  /// 語を探す行の長さの上限（VS Code `getWordAtText` の maxLen）。これより長い行はキャレットの周りの窓（`wordWindow`）で探す。
  public static let maxLineLength = 1000

  /// 語を探す窓——行（`line`、改行を除く）が長ければ [キャレット − 499, キャレット + 501)（VS Code は 1 始まりの桁の
  /// 前後 `maxLineLength / 2`。窓の端にかかる語は窓で切れる）。
  public static func wordWindow(caret: Int, line: NSRange) -> NSRange {
    guard line.length > maxLineLength else { return line }
    let column = caret + 1
    let start = max(line.location, column - maxLineLength / 2)
    let end = min(NSMaxRange(line), column + maxLineLength / 2)
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
    func visit(
      _ match: NSTextCheckingResult?, _: NSRegularExpression.MatchingFlags,
      _ stop: UnsafeMutablePointer<ObjCBool>
    ) {
      guard let range = match?.range, range.location <= position else {
        stop.pointee = true
        return
      }
      guard NSMaxRange(range) >= position else { return }
      stop.pointee = true
      guard NSMaxRange(range) >= NSMaxRange(selection) - textStart else { return }
      found = NSRange(location: textStart + range.location, length: range.length)
    }
    wordPattern.enumerateMatches(
      in: text, range: NSRange(location: 0, length: length), using: visit)
    return found
  }

  /// 語 `word`（本文の区間）の全出現（語の規則。自分を含む）。
  public static func wordOccurrences(
    of word: NSRange, in text: TextRope, window: Int = TextSearch.scanWindow
  ) -> [NSRange] {
    guard word.length > 0, NSMaxRange(word) <= text.length else { return [] }
    return TextSearch.matches(
      of: text.substring(word), in: text, rule: .word, limit: limit, window: window)
  }

  /// VS Code の既定の語の正規表現（`DEFAULT_WORD_REGEXP`）。JS の `\d`・`\w` は ASCII だけに当たる（u フラグ無し）ので、
  /// Unicode 全体に当たる ICU の `\d`・`\w` は使わず ASCII の文字クラスで書く。
  private static let wordPattern: NSRegularExpression = {
    let escaped = WordSeparators.characters.map { "\\\($0)" }.joined()
    // swiftlint:disable:next force_try
    return try! NSRegularExpression(
      pattern: "(-?[0-9]*\\.[0-9][A-Za-z0-9_]*)|([^\(escaped)\\s]+)")
  }()
}
