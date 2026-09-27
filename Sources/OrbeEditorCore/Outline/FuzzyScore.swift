// microsoft/vscode の src/vs/base/common/filters.ts（commit f83f3fbaccdbb2b6232c416e097e8da5e3ebfdfe、MIT License）の
// `fuzzyScore` と `createMatches` を Swift に翻訳したもの。

/// VS Code の tree で文字を打って絞り込むときの照合（`FindFilter` の既定の fuzzy。アウトラインのビューも同じ）。
/// 1 つの絞り込み文字列から作り、名前ごとに `matches(_:)` を呼ぶ。行列と語のバッファを使い回すので、1 本のスレッドで使う。
///
/// 小文字化は Swift の `lowercaseMapping`（`lowercased()` と同じ）で、JS の `toLowerCase` と違い語末の Σ を ς にしない。
final class FuzzyScorer {
  private static let maxLength = 128
  private static let rowStride = maxLength + 1

  private let pattern: UnsafeMutablePointer<UInt16>
  private let patternLow: UnsafeMutablePointer<UInt16>
  private let patternLength: Int

  // `word` と `wordLow` は先頭 `rowStride` 単位までを持つ（区切りの判定の `codePointAt` が最後の字の次の単位を読むため）。
  private let word: UnsafeMutablePointer<UInt16>
  private let wordLow: UnsafeMutablePointer<UInt16>
  private var wordLength = 0
  private var wordLowStored = 0

  private let minWordMatchPos: UnsafeMutablePointer<Int>
  private let maxWordMatchPos: UnsafeMutablePointer<Int>
  private let table: UnsafeMutablePointer<Int32>
  private let diag: UnsafeMutablePointer<Int32>
  private let arrows: UnsafeMutablePointer<Arrow>
  private let positions: UnsafeMutablePointer<Int>

  private enum Arrow: UInt8 {
    case none = 0
    case diag = 1
    case left = 2
    case leftLeft = 3
  }

  private static let noScore = Int32.min

  init(pattern text: String) {
    let maxLength = Self.maxLength
    pattern = .allocate(capacity: maxLength)
    patternLow = .allocate(capacity: maxLength)
    patternLength =
      Self.load(text, into: pattern, lowercased: patternLow, capacity: maxLength).units

    word = .allocate(capacity: Self.rowStride)
    wordLow = .allocate(capacity: Self.rowStride)
    minWordMatchPos = .allocate(capacity: maxLength)
    maxWordMatchPos = .allocate(capacity: maxLength)
    let cells = Self.rowStride * Self.rowStride
    table = .allocate(capacity: cells)
    table.initialize(repeating: 0, count: cells)
    diag = .allocate(capacity: cells)
    diag.initialize(repeating: 0, count: cells)
    arrows = .allocate(capacity: cells)
    arrows.initialize(repeating: .none, count: cells)
    positions = .allocate(capacity: maxLength)
  }

  deinit {
    pattern.deallocate()
    patternLow.deallocate()
    word.deallocate()
    wordLow.deallocate()
    minWordMatchPos.deallocate()
    maxWordMatchPos.deallocate()
    table.deallocate()
    diag.deallocate()
    arrows.deallocate()
    positions.deallocate()
  }

  /// `word` の一致した字の区間（UTF-16 の単位、昇順、隣り合う字はつなぐ）。一致しなければ nil。絞り込み文字列が空なら、
  /// tree と同じく一致で区間なし。
  func matches(_ word: String) -> [Range<Int>]? {
    guard patternLength > 0 else { return [] }
    load(word)
    guard let count = score() else { return nil }
    var ranges: [Range<Int>] = []
    for index in stride(from: count - 1, through: 0, by: -1) {
      let position = positions[index]
      if let last = ranges.last, last.upperBound == position {
        ranges[ranges.count - 1] = last.lowerBound..<(position + 1)
      } else {
        ranges.append(position..<(position + 1))
      }
    }
    return ranges
  }

  private func load(_ text: String) {
    let stored = Self.load(text, into: word, lowercased: wordLow, capacity: Self.rowStride)
    wordLength = min(stored.units, Self.maxLength)
    wordLowStored = stored.lowercased
  }

  /// `text` の UTF-16 と、それを小文字にした UTF-16 を、それぞれ先頭 `capacity` 単位まで置く。
  private static func load(
    _ text: String, into units: UnsafeMutablePointer<UInt16>,
    lowercased: UnsafeMutablePointer<UInt16>, capacity: Int
  ) -> (units: Int, lowercased: Int) {
    var stored = 0
    var lowStored = 0
    func append(_ unit: UInt16, to buffer: UnsafeMutablePointer<UInt16>, count: inout Int) {
      guard count < capacity else { return }
      buffer[count] = unit
      count += 1
    }
    for scalar in text.unicodeScalars {
      // 小文字化で UTF-16 の長さは縮まないので、原本の側が埋まれば小文字の側も埋まっている。
      guard stored < capacity else { break }
      if scalar.isASCII {
        let unit = UInt16(scalar.value)
        append(unit, to: units, count: &stored)
        append(unit >= 0x41 && unit <= 0x5A ? unit | 0x20 : unit, to: lowercased, count: &lowStored)
        continue
      }
      for unit in scalar.utf16 {
        append(unit, to: units, count: &stored)
      }
      if scalar.properties.changesWhenLowercased {
        for unit in scalar.properties.lowercaseMapping.utf16 {
          append(unit, to: lowercased, count: &lowStored)
        }
      } else {
        for unit in scalar.utf16 {
          append(unit, to: lowercased, count: &lowStored)
        }
      }
    }
    return (stored, lowStored)
  }

  /// 原本の `fuzzyScore`（patternStart と wordStart は 0、`firstMatchCanBeWeak` と `boostFullMatch` は真）。一致の位置を
  /// 降順に `positions` へ置き、その数を返す。点数そのものは使わないので、表の外で足し引きする分は写さない。
  private func score() -> Int? {
    guard wordLength > 0, patternLength <= wordLength, isPatternInWord() else { return nil }
    fillInMaxWordMatchPos()
    for row in 1...patternLength {
      let patternPos = row - 1
      let minWordPos = minWordMatchPos[patternPos]
      let nextMaxWordPos =
        patternPos + 1 < patternLength ? maxWordMatchPos[patternPos + 1] : wordLength
      for wordPos in minWordPos..<nextMaxWordPos {
        fillCell(row: row, wordPos: wordPos, minWordPos: minWordPos)
      }
    }
    return backtrack()
  }

  private func fillCell(row: Int, wordPos: Int, minWordPos: Int) {
    let patternPos = row - 1
    let column = wordPos + 1
    let here = row * Self.rowStride + column
    let above = here - Self.rowStride

    var score = Self.noScore
    if wordPos <= maxWordMatchPos[patternPos] {
      score = doScore(patternPos: patternPos, wordPos: wordPos, newMatchStart: diag[above - 1] == 0)
    }

    var diagScore: Int32 = 0
    let canComeDiag = score != Self.noScore
    if canComeDiag {
      diagScore = score + table[above - 1]
    }

    let canComeLeft = wordPos > minWordPos
    let leftScore = canComeLeft ? table[here - 1] + (diag[here - 1] > 0 ? -5 : 0) : 0

    let canComeLeftLeft = wordPos > minWordPos + 1 && diag[here - 1] > 0
    let leftLeftScore = canComeLeftLeft ? table[here - 2] + (diag[here - 2] > 0 ? -5 : 0) : 0

    if canComeLeftLeft && (!canComeLeft || leftLeftScore >= leftScore)
      && (!canComeDiag || leftLeftScore >= diagScore)
    {
      table[here] = leftLeftScore
      arrows[here] = .leftLeft
      diag[here] = 0
    } else if canComeLeft && (!canComeDiag || leftScore >= diagScore) {
      table[here] = leftScore
      arrows[here] = .left
      diag[here] = 0
    } else if canComeDiag {
      table[here] = diagScore
      arrows[here] = .diag
      diag[here] = diag[above - 1] + 1
    } else {
      preconditionFailure("not possible")
    }
  }

  private func backtrack() -> Int {
    var row = patternLength
    var column = wordLength
    var count = 0
    var backwardsDiagLength: Int32 = 0
    while row >= 1 {
      let here = row * Self.rowStride
      var diagColumn = column
      repeat {
        let arrow = arrows[here + diagColumn]
        if arrow == .leftLeft {
          diagColumn -= 2
        } else if arrow == .left {
          diagColumn -= 1
        } else {
          break
        }
      } while diagColumn >= 1

      if backwardsDiagLength > 1
        && patternLow[row - 1] == wordLow[column - 1]
        && !isUpperCaseAt(diagColumn - 1)
        && backwardsDiagLength + 1 > diag[here + diagColumn]
      {
        diagColumn = column
      }

      if diagColumn == column {
        backwardsDiagLength += 1
      } else {
        backwardsDiagLength = 1
      }

      row -= 1
      column = diagColumn - 1
      positions[count] = column
      count += 1
    }
    return count
  }

  private func isPatternInWord() -> Bool {
    var patternPos = 0
    var wordPos = 0
    while patternPos < patternLength && wordPos < wordLength {
      if patternLow[patternPos] == wordLow[wordPos] {
        minWordMatchPos[patternPos] = wordPos
        patternPos += 1
      }
      wordPos += 1
    }
    return patternPos == patternLength
  }

  private func fillInMaxWordMatchPos() {
    var patternPos = patternLength - 1
    var wordPos = wordLength - 1
    while patternPos >= 0 && wordPos >= 0 {
      if patternLow[patternPos] == wordLow[wordPos] {
        maxWordMatchPos[patternPos] = wordPos
        patternPos -= 1
      }
      wordPos -= 1
    }
  }

  private func doScore(patternPos: Int, wordPos: Int, newMatchStart: Bool) -> Int32 {
    guard patternLow[patternPos] == wordLow[wordPos] else { return Self.noScore }

    var score: Int32 = 1
    var isGapLocation = false
    if wordPos == patternPos {
      score = pattern[patternPos] == word[wordPos] ? 7 : 5
    } else if isUpperCaseAt(wordPos) && (wordPos == 0 || !isUpperCaseAt(wordPos - 1)) {
      score = pattern[patternPos] == word[wordPos] ? 7 : 5
      isGapLocation = true
    } else if isSeparatorAt(wordPos) && (wordPos == 0 || !isSeparatorAt(wordPos - 1)) {
      score = 5
    } else if isSeparatorAt(wordPos - 1) || isWhitespaceAt(wordPos - 1) {
      score = 5
      isGapLocation = true
    }

    if !isGapLocation {
      isGapLocation =
        isUpperCaseAt(wordPos) || isSeparatorAt(wordPos - 1) || isWhitespaceAt(wordPos - 1)
    }

    if patternPos == 0 {
      if wordPos > 0 {
        score -= isGapLocation ? 3 : 5
      }
    } else if newMatchStart {
      score += isGapLocation ? 2 : 0
    } else {
      score += isGapLocation ? 0 : 1
    }

    if wordPos + 1 == wordLength {
      score -= isGapLocation ? 3 : 5
    }
    return score
  }

  // 小文字化で UTF-16 の長さは縮まないので、原本の長さ未満の添字は `wordLow` の側でも範囲内。
  private func isUpperCaseAt(_ position: Int) -> Bool {
    word[position] != wordLow[position]
  }

  private func isSeparatorAt(_ index: Int) -> Bool {
    guard index >= 0, index < wordLowStored else { return false }
    var code = UInt32(wordLow[index])
    if code >= 0xD800 && code <= 0xDBFF && index + 1 < wordLowStored {
      let low = UInt32(wordLow[index + 1])
      if low >= 0xDC00 && low <= 0xDFFF {
        code = (code - 0xD800) * 0x400 + (low - 0xDC00) + 0x10000
      }
    }
    switch code {
    case 0x5F, 0x2D, 0x2E, 0x20, 0x2F, 0x5C, 0x27, 0x22, 0x3A, 0x24, 0x3C, 0x3E, 0x28, 0x29, 0x5B,
      0x5D, 0x7B, 0x7D:
      return true
    default:
      return Self.isEmojiImprecise(code)
    }
  }

  private func isWhitespaceAt(_ index: Int) -> Bool {
    guard index >= 0, index < wordLowStored else { return false }
    let code = wordLow[index]
    return code == 0x20 || code == 0x09
  }

  /// VS Code src/vs/base/common/strings.ts の `isEmojiImprecise`。
  private static func isEmojiImprecise(_ code: UInt32) -> Bool {
    (0x1F1E6...0x1F1FF).contains(code) || code == 8986 || code == 8987 || code == 9200
      || code == 9203 || (9728...10175).contains(code) || code == 11088 || code == 11093
      || (127744...128591).contains(code) || (128640...128764).contains(code)
      || (128992...129008).contains(code) || (129280...129535).contains(code)
      || (129648...129782).contains(code)
  }
}
