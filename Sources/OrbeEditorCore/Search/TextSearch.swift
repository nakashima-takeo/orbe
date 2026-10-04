import Foundation

/// 一致の規則。⌘F・出現の強調・⌘D・⌘⇧L は、どれもここから一致を引く（⌘D は ⌘F の設定に従う——VS Code の
/// `MultiCursorSession` が検索の設定を使うのと同じ関係）。
public enum MatchRule: Equatable, Sendable {
  /// ⌘F の規則——大小を区別しない素の文字列。
  case find
  /// 語の規則——大小を区別し、両端が語の境の一致だけ（`WordBoundaries`）。
  case word
}

/// ファイル内検索の規則——needle の一致の列と、位置・選択に対する「現在／次／前」（VS Code `FindModel` と同じ起点）。
/// 状態を持たず、「現在の一致」は選択とちょうど重なる一致。
public enum TextSearch {
  /// 一致を集める上限（VS Code の MATCHES_LIMIT）。ここで打ち切り、件数は「上限+」と見せる。
  public static let limit = 19999

  /// 重ならない一致（昇順）を `limit` 件まで。needle が空なら空。
  public static func matches(
    of needle: String, in text: TextRope, rule: MatchRule = .find, limit: Int = limit,
    window: Int = scanWindow
  ) -> [NSRange] {
    search(
      SearchQuestion(needle: needle, rule: rule), in: text, from: 0, limit: limit, window: window)
  }

  /// 位置 `offset` 以降に始まる最初の一致。無ければ先頭から探す（回り込む。VS Code の `findNextMatch`）。
  public static func firstMatch(
    of needle: String, in text: TextRope, rule: MatchRule, from offset: Int,
    window: Int = scanWindow
  ) -> NSRange? {
    let question = SearchQuestion(needle: needle, rule: rule)
    return search(question, in: text, from: offset, limit: 1, window: window).first
      ?? (offset > 0 ? search(question, in: text, from: 0, limit: 1, window: window).first : nil)
  }

  /// 本文の写しを探す窓の大きさ（UTF-16）。
  public static let scanWindow = 65_536

  private static func search(
    _ question: SearchQuestion, in text: TextRope, from start: Int, limit: Int, window: Int
  ) -> [NSRange] {
    let needle = question.needle
    guard !needle.isEmpty else { return [] }
    let length = (needle as NSString).length
    switch question.rule {
    case .find:
      // 大小無視の一致は、畳み込みで字数が変わる字（合字など）があると needle より長くなりうる（1 字が最大 3 字に開く）。
      return scan(
        text, from: start, maximumLength: length * 4, limit: limit, window: window,
        find: { string, range in
          string.range(of: needle, options: [.caseInsensitive, .literal], range: range)
        })
    case .word:
      var boundaries = WordBoundaries(text: text)
      return scan(
        text, from: start, maximumLength: length, limit: limit, window: window,
        find: { string, range in string.range(of: needle, options: [.literal], range: range) },
        accept: { string, found, base in
          boundaries.isBoundary(at: base + found.location, in: string, base: base)
            && boundaries.isBoundary(at: base + NSMaxRange(found), in: string, base: base)
        })
    }
  }

  /// 本文の写しを `start` から窓ごとの NSString にして、重ならない一致を順に集める——全文を 1 つの文字列に写さない（窓の
  /// 大きさぶんだけを一時に持つ）。窓は `maximumLength` を越える重なりを持ち、窓の終わりの重なりより手前で始まる
  /// 一致だけを受けるので、全文を 1 つの NSString にして探したのと同じ一致を同じ順に返す。`find` は窓の中の探す区間から
  /// 最初の一致（窓の中の区間。無ければ `NSNotFound`）、`accept` はその一致を受けるか（窓は一致の前後 1 単位を含む。
  /// `base` は窓の始まりのオフセット）。
  static func scan(
    _ text: TextRope, from start: Int = 0, maximumLength: Int, limit: Int, window: Int,
    find: (NSString, NSRange) -> NSRange,
    accept: (NSString, NSRange, Int) -> Bool = { _, _, _ in true }
  ) -> [NSRange] {
    let overlap = maximumLength + 1
    var result: [NSRange] = []
    var cursor = max(0, start)
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
        if accept(string, found, base) {
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

/// 語の規則の境——VS Code の語の境（どちらかの字が区切り・空白・改行、または本文の端。`isValidMatch`）に、CJK を含む
/// 通常の字の並びの中の OS の語の分割の境を足したもの（⌘D・⌥←→・ダブルクリックが語を選ぶのと同じ分類 `LineWords`）。
/// 日本語の並びの中で選んだ語（「東京都に行く」の「東京」）も、同じ語の一致として見つかる。分割した並びは覚えて、同じ並びの
/// 一致では分割し直さない。
struct WordBoundaries {
  /// 分割を読む並びの、位置の前後それぞれの上限（面の語の規則の窓と同じ大きさ）。
  static let reach = 1024

  let text: TextRope
  private var run: (range: Range<Int>, words: LineWords)?

  init(text: TextRope) {
    self.text = text
  }

  /// 位置 `offset`（本文のオフセット）の前後で語が切れるか。`string` は `base` から始まる本文の窓で、位置の前後 1 単位を
  /// 含む（含まなければ本文から読む）。
  mutating func isBoundary(at offset: Int, in string: NSString, base: Int) -> Bool {
    guard offset > 0, offset < text.length else { return true }
    func unit(_ at: Int) -> UInt16 {
      let local = at - base
      return local >= 0 && local < string.length
        ? string.character(at: local) : text.units(in: NSRange(location: at, length: 1))[0]
    }
    let before = unit(offset - 1)
    let after = unit(offset)
    guard Self.isWordUnit(before), Self.isWordUnit(after) else { return true }
    let leading = UTF16.isTrailSurrogate(before) && offset >= 2 ? unit(offset - 2) : before
    guard LineWords.isCJK(leading) || LineWords.isCJK(after) else { return false }
    let words = segmented(around: offset)
    return words.words.isSegmentBoundary(at: offset - words.range.lowerBound)
  }

  /// 通常の字（区切り・空白・改行でない）か。
  private static func isWordUnit(_ unit: UInt16) -> Bool {
    unit != 0x0A && unit != 0x0D && LineWords.wordClass(unit) == .regular
  }

  /// `offset` を含む通常の字の並び（前後 `reach` まで）と、その語の分割。
  private mutating func segmented(around offset: Int) -> (range: Range<Int>, words: LineWords) {
    if let run, run.range.lowerBound < offset, offset < run.range.upperBound { return run }
    let lower = max(0, offset - Self.reach)
    let upper = min(text.length, offset + Self.reach)
    let units = text.units(in: NSRange(location: lower, length: upper - lower))
    var start = offset - lower
    while start > 0, Self.isWordUnit(units[start - 1]) { start -= 1 }
    var end = offset - lower
    while end < units.count, Self.isWordUnit(units[end]) { end += 1 }
    let found = (
      range: (lower + start)..<(lower + end), words: LineWords(ContiguousArray(units[start..<end]))
    )
    run = found
    return found
  }
}
