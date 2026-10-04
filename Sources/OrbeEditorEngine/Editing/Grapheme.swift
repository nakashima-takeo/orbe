/// 書記素——Unicode の拡張書記素クラスタ（UAX #29。Swift の `Character` の区切り）。位置の前後の窓だけを読み、行や文書の
/// 長さに依らない。窓（前後 `reach` 単位）より長い書記素は窓の端で切れる。
enum Grapheme {
  static let reach = 64

  /// `offset` を含む書記素の区間（`count` 単位の並びの中。外なら長さ 0）。`unit` は位置の単位を返す。
  static func cluster(
    containing offset: Int, count: Int, unit: (Int) -> UInt16,
    units: (Range<Int>) -> ContiguousArray<UInt16>
  ) -> Range<Int> {
    guard offset >= 0, offset < count else { return offset..<offset }
    let start = windowStart(before: offset, unit: unit)
    let window = units(start..<min(count, offset + reach))
    var location = start
    for character in String(decoding: window, as: UTF16.self) {
      let end = location + character.utf16.count
      if offset < end { return location..<end }
      location = end
    }
    return offset..<offset + 1
  }

  /// 窓の始まり。書記素の境として数えるので、サロゲートの対の中と国旗の字（regional indicator）の並びの中を避ける——
  /// 国旗は並びの頭から 2 字ずつ組むので、並びの途中から数えると組がずれる。
  private static func windowStart(before offset: Int, unit: (Int) -> UInt16) -> Int {
    var start = max(0, offset - reach)
    if start > 0, UTF16.isTrailSurrogate(unit(start)) { start -= 1 }
    while start >= 2, unit(start - 2) == 0xD83C, (0xDDE6...0xDDFF).contains(unit(start - 1)) {
      start -= 2
    }
    return start
  }
}
