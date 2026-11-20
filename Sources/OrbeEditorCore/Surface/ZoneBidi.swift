import CoreText

/// 開いている埋め込み・上書き・isolate の字（開いた順。対応の取り方は UAX #9 の X6a・X7）。
struct OpenControls {
  private(set) var units: [UInt16] = []

  /// 字 `unit` を読む。isolate の終わりが、開いている isolate に対応しなければ偽（読んだ字は何も閉じない）。
  @discardableResult
  mutating func read(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x2066...0x2068, 0x202A, 0x202B, 0x202D, 0x202E: units.append(unit)
    case 0x202C: if let last = units.last, !Self.isIsolate(last) { units.removeLast() }
    case 0x2069:
      guard let isolate = units.lastIndex(where: Self.isIsolate) else { return false }
      units.removeSubrange(isolate...)
    default: break
    }
    return true
  }

  /// 開いている字を、閉じる順に閉じる字。
  var closers: [UInt16] { units.reversed().map { Self.isIsolate($0) ? 0x2069 : 0x202C } }

  private static func isIsolate(_ unit: UInt16) -> Bool { (0x2066...0x2068).contains(unit) }
}

/// 段落の頭から段落の中の位置までに開いた制御字——余白なしの文の並び（`bare`。元の文のまま）と、組んだ文の並び
/// （`composed`。コードの中で開いた字はコードの終わりで閉じ、コードの中の対にならない isolate の終わりは何も閉じない
/// → `ZoneComposition`）。区切りの頭で引き継ぐ。コードの途中から始まる区切りは、コードの中で区切りの前に開いた字を
/// 引き継がない。
struct CarriedControls {
  private(set) var bare = OpenControls()
  private(set) var composed = OpenControls()
  /// 読んだ所の後ろで終わる最初の見え方。
  private(set) var style: StyleCursor
  private let source: [UInt16]
  private let styles: [ZoneTextStyle]
  private var offset: Int

  /// 文 `source`（見え方 `styles`）の位置 `offset`（段落の頭。`style` はそこより後ろで終わる最初の見え方）から読む。
  init(_ source: [UInt16], styles: [ZoneTextStyle], from offset: Int, style: StyleCursor) {
    self.source = source
    self.styles = styles
    self.offset = offset
    self.style = style
  }

  /// 位置 `target` まで読む。
  mutating func read(to target: Int) {
    while offset < target {
      style.advance(to: offset, in: styles)
      let padded =
        style.index < styles.count
        && (styles[style.index].leadingPadding > 0 || styles[style.index].trailingPadding > 0)
      bare.read(source[offset])
      if !padded { composed.read(source[offset]) }
      offset += 1
    }
    style.advance(to: offset, in: styles)
  }
}

/// 見え方の列の中の、位置より後ろで終わる最初の見え方（番号と、その見え方が当たり始める文の位置）。
struct StyleCursor {
  private(set) var index: Int
  private(set) var offset: Int

  init(index: Int = 0, offset: Int = 0) {
    self.index = index
    self.offset = offset
  }

  /// 位置 `position` より後ろで終わる最初の見え方まで進む（長さ 0 の見え方は飛ばす）。
  mutating func advance(to position: Int, in styles: [ZoneTextStyle]) {
    while index < styles.count, offset + styles[index].length <= position {
      offset += styles[index].length
      index += 1
    }
  }
}

extension ZoneComposition {
  /// 文 `source` の範囲 `range` を段落とみなしたとき右から左か——最初の、向きを持つ字で決まる（UAX #9 の P2・P3。isolate の
  /// 中の字は飛ばし、向きを持つ字が無ければ左から右）。長い範囲は 4,096 字ずつ、区切りの前で開いた制御字を頭に置いて判定
  /// する——Core Text が長さの限りを外して組む仕事は、右から左の字の続きの長さの 2 乗に伸びる。区切りが右から左なら右から
  /// 左。そうでなければ、区切りの末尾に U+200F を足して判定し直し、左から右のままなら左から右（区切りに左から右の字が
  /// ある）、右から左に変われば区切りに向きを持つ字が無いので次の区切りへ。区切りはサロゲートの対を割らない。区切りは
  /// 段落の区切りの字（UAX #9 の B 類）でも切り、その字は判定の文に入れず、その後ろは開いた制御字を引き継がない——Core Text
  /// はその字でも段落を切るので、入れると、その字の後ろの字が判定の答えを決める。
  static func isRightToLeft(_ source: [UInt16], _ range: Range<Int>) -> Bool {
    var open = OpenControls()
    var lower = range.lowerBound
    while lower < range.upperBound {
      var upper = min(range.upperBound, lower + 4_096)
      if upper < range.upperBound, UTF16.isLeadSurrogate(source[upper - 1]) { upper -= 1 }
      let separator = source[lower..<upper].firstIndex(where: isParagraphSeparator)
      if let separator { upper = separator }
      var probe = open.units + source[lower..<upper]
      for unit in source[lower..<upper] { open.read(unit) }
      probe += open.closers
      if isRightToLeft(probe) { return true }
      guard upper < range.upperBound, isRightToLeft(probe + [0x200F]) else { return false }
      if separator != nil {
        lower = upper + 1
        open = OpenControls()
      } else {
        lower = upper
      }
    }
    return false
  }

  /// Core Text が段落を切る字（UAX #9 の B 類。改行は段落の区切りの外）。
  private static func isParagraphSeparator(_ unit: UInt16) -> Bool {
    [0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2029].contains(unit)
  }

  /// 字の並び `units` を段落として組んだとき右から左か。Core Text は段落の向きを返さないので、末尾に空白を 1 つ足して
  /// 組み、その空白の向きを読む（行末の空白は段落の向きで組まれる。UAX #9 の L1）。
  private static func isRightToLeft(_ units: [UInt16]) -> Bool {
    let probe = units + [0x20]
    let string = probe.withUnsafeBufferPointer {
      CFStringCreateWithCharacters(nil, $0.baseAddress, $0.count)!
    }
    let space = probe.count - 1
    let line = CTTypesetterCreateLine(
      typesetter(CFAttributedStringCreate(nil, string, nil)),
      CFRange(location: space, length: 1))
    let run = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).first {
      let range = CTRunGetStringRange($0)
      return range.location <= space && space < range.location + range.length
    }
    return run.map { CTRunGetStatus($0).contains(.rightToLeft) } ?? false
  }
}
