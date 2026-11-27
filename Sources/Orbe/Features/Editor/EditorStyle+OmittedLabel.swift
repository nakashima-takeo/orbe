import Foundation

extension EditorStyle {
  /// 1 行で描く上限を越えて打ち切った行の末尾の印（「ほか 1.2万字」）。数は 1 万（英語は千）以上を 1 桁の小数で略し、
  /// 丸めて次の単位に届けば次の単位で出す（999,999 は「1,000K」でなく「1M」）。文言は UI の言語 `language` の、数の
  /// 書き方（数字・桁区切り・小数点）は地域 `locale` のもの。折り返す面は、打ち切った行で打つたびに印の幅を引くので、
  /// 地域の書き方は作るときに 1 度だけ引き、数は手で組む——打鍵のたびに数の書式（Foundation）を通さない。
  struct OmittedLabel: Sendable {
    private let ladder: [(unit: Double, suffix: String)]
    /// 文言の、数の前と後ろ。
    private let prefix: String
    private let suffix: String
    /// 0〜9 の数字。
    private let digits: [String]
    private let separator: String
    /// 桁区切りの間の桁の数（いちばん下の組と、それより上の組）と、桁区切りを入れる整数の最小の桁の数。
    private let group: Int
    private let upperGroup: Int
    private let groupedFrom: Int
    private let decimal: String

    init(language: Language, locale: Locale) {
      ladder =
        language == .ja
        ? [(10_000, "万"), (100_000_000, "億")] : [(1_000, "K"), (1_000_000, "M"), (1e9, "B")]
      let template = L10n.string(.editorOmittedCharacters, language)
      let marker = template.range(of: "%@") ?? template.endIndex..<template.endIndex
      prefix = String(template[..<marker.lowerBound])
      suffix = String(template[marker.upperBound...])
      let format = NumberFormatter()
      format.locale = locale
      format.numberStyle = .decimal
      digits = (0...9).map { format.string(from: $0 as NSNumber) ?? String($0) }
      separator = format.groupingSeparator
      group = max(1, format.groupingSize)
      upperGroup = format.secondaryGroupingSize > 0 ? format.secondaryGroupingSize : group
      let first = Int(pow(10, Double(group)))
      groupedFrom =
        format.string(from: first as NSNumber)?.contains(separator) == true ? group + 1 : group + 2
      decimal = format.decimalSeparator
    }

    func callAsFunction(_ count: Int) -> String {
      var value = integer(count)
      var index = ladder.lastIndex { Double(count) >= $0.unit }
      while let i = index {
        let tenths = Int((Double(count) / ladder[i].unit * 10).rounded())
        if i + 1 < ladder.count, Double(tenths) / 10 * ladder[i].unit >= ladder[i + 1].unit {
          index = i + 1
          continue
        }
        value =
          integer(tenths / 10) + (tenths % 10 == 0 ? "" : decimal + digits[tenths % 10])
          + ladder[i].suffix
        index = nil
      }
      return prefix + value + suffix
    }

    /// 0 以上の整数 `value` を、地域の数字と桁区切りで書く。
    private func integer(_ value: Int) -> String {
      let places = String(value).utf8.map { Int($0) - 0x30 }
      var result = ""
      for (index, digit) in places.enumerated() {
        let below = places.count - index
        if index > 0, places.count >= groupedFrom, below >= group,
          (below - group) % upperGroup == 0
        {
          result += separator
        }
        result += digits[digit]
      }
      return result
    }
  }
}
