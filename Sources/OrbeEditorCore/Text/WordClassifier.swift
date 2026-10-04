import CoreFoundation
import Foundation

/// 字の種類（VS Code の `WordCharacterClass`）。
public enum WordClass: Sendable {
  case regular, whitespace, separator
}

/// 語の種類（VS Code の `WordType`）。
public enum WordKind: Sendable {
  case regular, separator
}

/// 行の中の語（VS Code の `IFindWordResult`）。位置は行の中の UTF-16 の距離。
public struct Word: Equatable, Sendable {
  public var start: Int
  public var end: Int
  public var kind: WordKind
  /// 語の直後（前の語を探したときは直前）の字の種類。
  public var nextClass: WordClass
}

/// 1 行の語の規則（VS Code の `WordCharacterClassifier` と `WordOperations` の行の中の探索）。空白は space と tab、区切りは
/// VS Code の区切り文字、それ以外は通常の字で、同じ種類の最長の並びが 1 語。通常の字の並びが CJK（漢字・かな・ハングル
/// など）を含むときは、並びの中で OS の語の分割（ロケールは `ja` に固定）の境でも止まる——VS Code で語の分割のロケールに
/// `ja` を置いたときと同じ形で、分割の境は記号と空白の規則に足すだけ。面の語の移動・削除・選択（⌘D の語を含む）と、検索の
/// 語の規則の境が、この 1 つの分類を使う。
public struct LineWords {
  public let units: ContiguousArray<UInt16>
  /// OS の語の分割で得た語（行の中の区間。CJK を含む通常の字の並びの中だけ）。
  private let segments: [Range<Int>]

  public init(_ units: ContiguousArray<UInt16>) {
    self.units = units
    segments = Self.segments(of: units)
  }

  public static func wordClass(_ unit: UInt16) -> WordClass {
    if unit == 0x20 || unit == 0x09 { return .whitespace }
    return WordSeparators.units.contains(unit) ? .separator : .regular
  }

  private func wordClass(at index: Int) -> WordClass { Self.wordClass(units[index]) }

  /// `column` の前で終わる語（VS Code の `_doFindPreviousWordOnLine`。`column` は位置 = 1 始まりの桁 − 1）。
  public func previousWord(before column: Int) -> Word? {
    var kind: WordKind?
    let segment = previousSegment(atOrBefore: column - 1)
    var index = column - 1
    while index >= 0 {
      let cls = wordClass(at: index)
      if let segment, index == segment.lowerBound {
        return Word(
          start: segment.lowerBound, end: segment.upperBound, kind: .regular, nextClass: cls)
      }
      switch (cls, kind) {
      case (.regular, .separator?), (.separator, .regular?), (.whitespace, _?):
        return Word(
          start: index + 1, end: endOfWord(kind!, from: index + 1), kind: kind!, nextClass: cls)
      case (.regular, _):
        kind = .regular
      case (.separator, _):
        kind = .separator
      case (.whitespace, nil):
        break
      }
      index -= 1
    }
    return kind.map {
      Word(start: 0, end: endOfWord($0, from: 0), kind: $0, nextClass: .whitespace)
    }
  }

  /// `column` 以降で始まる（`column` を含む）語（VS Code の `_doFindNextWordOnLine`）。
  public func nextWord(from column: Int) -> Word? {
    var kind: WordKind?
    let segment = nextSegment(atOrAfter: column)
    var index = column
    while index < units.count {
      let cls = wordClass(at: index)
      if let segment, index == segment.lowerBound {
        return Word(
          start: segment.lowerBound, end: segment.upperBound, kind: .regular, nextClass: cls)
      }
      switch (cls, kind) {
      case (.regular, .separator?), (.separator, .regular?), (.whitespace, _?):
        return Word(
          start: startOfWord(kind!, from: index - 1), end: index, kind: kind!, nextClass: cls)
      case (.regular, _):
        kind = .regular
      case (.separator, _):
        kind = .separator
      case (.whitespace, nil):
        break
      }
      index += 1
    }
    return kind.map {
      Word(
        start: startOfWord($0, from: units.count - 1), end: units.count, kind: $0,
        nextClass: .whitespace)
    }
  }

  /// VS Code の `_findEndOfWord`。
  private func endOfWord(_ kind: WordKind, from start: Int) -> Int {
    let segment = nextSegment(atOrAfter: start)
    var index = start
    while index < units.count {
      if let segment, index == segment.upperBound { return index }
      if Self.ends(kind, at: wordClass(at: index)) { return index }
      index += 1
    }
    return units.count
  }

  /// VS Code の `_findStartOfWord`。
  private func startOfWord(_ kind: WordKind, from start: Int) -> Int {
    let segment = previousSegment(atOrBefore: start)
    var index = start
    while index >= 0 {
      if let segment, index == segment.lowerBound { return index }
      if Self.ends(kind, at: wordClass(at: index)) { return index + 1 }
      index -= 1
    }
    return 0
  }

  private static func ends(_ kind: WordKind, at cls: WordClass) -> Bool {
    cls == .whitespace || (kind == .regular && cls == .separator)
      || (kind == .separator && cls == .regular)
  }

  /// 始まりが `offset` 以前の最後の分割の語（VS Code の `findPrevIntlWordBeforeOrAtOffset`）。
  private func previousSegment(atOrBefore offset: Int) -> Range<Int>? {
    segments.last { $0.lowerBound <= offset }
  }

  /// 始まりが `offset` 以降の最初の分割の語（VS Code の `findNextIntlWordAtOrAfterOffset`）。
  private func nextSegment(atOrAfter offset: Int) -> Range<Int>? {
    segments.first { $0.lowerBound >= offset }
  }

  // MARK: - OS の語の分割

  /// CJK を含む通常の字の並びそれぞれを OS の語の分割に掛けた語の列（昇順）。
  private static func segments(of units: ContiguousArray<UInt16>) -> [Range<Int>] {
    var result: [Range<Int>] = []
    var start = 0
    while start < units.count {
      guard wordClass(units[start]) == .regular else {
        start += 1
        continue
      }
      var end = start
      var cjk = false
      while end < units.count, wordClass(units[end]) == .regular {
        if isCJK(units[end]) { cjk = true }
        end += 1
      }
      if cjk { result += tokens(units, in: start..<end) }
      start = end
    }
    return result
  }

  private static let locale = Locale(identifier: "ja")

  private static func tokens(_ units: ContiguousArray<UInt16>, in run: Range<Int>) -> [Range<Int>] {
    let string = units.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress! + run.lowerBound, run.count)!
    }
    let tokenizer = CFStringTokenizerCreate(
      nil, string, CFRange(location: 0, length: run.count), kCFStringTokenizerUnitWord,
      locale as CFLocale)
    var result: [Range<Int>] = []
    while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
      let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
      let lower = run.lowerBound + range.location
      result.append(lower..<(lower + range.length))
    }
    return result
  }

  /// 通常の字どうしの間 `index`（1…`units.count - 1`）が、OS の語の分割の境か（CJK を含む並びの中だけ。それ以外の並びは
  /// 1 語なので境ではない）。
  func isSegmentBoundary(at index: Int) -> Bool {
    segments.contains { $0.lowerBound == index || $0.upperBound == index }
  }

  /// 漢字・かな・ハングル・CJK の記号（々〆ー など）と、補助面の漢字（サロゲートの上位）。
  static func isCJK(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3005...0x3007, 0x3021...0x3029, 0x3031...0x3035,
      0x3040...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF,
      0xF900...0xFAFF, 0xFF66...0xFF9F, 0xD840...0xD8BF:
      return true
    default:
      return false
    }
  }
}
