import Foundation

/// 絵文字フォント設定の値。noto=同梱 Noto Color Emoji（sbix・フラット字形）/
/// apple=Apple Color Emoji（macOS 標準）。端末セル（font-codepoint-map）と chrome
/// （ChromeFontResolver）の両方がこの 1 値で切り替わる。
enum EmojiFontMode: String, CaseIterable {
  case noto, apple

  /// 設定パレット行・descriptor display の表示ラベル（`ThemeMode.label` 前例＝モード自身が名乗る）。
  /// 並行配列で位置結合するとラベル取り違えが黙って通るため、写像はここ 1 箇所に持つ。
  var labelKey: L10nKey {
    switch self {
    case .noto: return .settingsEmojiFontNoto
    case .apple: return .settingsEmojiFontApple
    }
  }
}

extension EmojiFontMode: SettingConvertible {
  init?(settingValue: SettingValue) {
    guard case .string(let raw) = settingValue, let mode = EmojiFontMode(rawValue: raw) else {
      return nil
    }
    self = mode
  }
  var settingValue: SettingValue { .string(rawValue) }
}

/// emoji-presentation（既定で絵文字として描かれる）コードポイントの全域集合。
/// UCD テーブルをコミットせず、実行時に `Unicode.Scalar.Properties.isEmojiPresentation` を
/// 全平面走査（U+0000–U+1FFFF・起動時 1 回・キャッシュ）して範囲圧縮で導出する。chrome 側
/// `TitleGlyphs.isEmojiPresentation` と同一の判定源のため、端末セルとタブの対象集合が定義上一致する。
/// 肌色修飾子 U+1F3FB–1F3FF も Emoji_Presentation=Yes で自然に含まれる。ZWJ・VS16 は
/// default-ignorable でクラスタ shaping 側が処理するため map 不要。
enum EmojiPresentationRanges {
  /// 範囲圧縮済みの閉区間列（昇順）。
  static let ranges: [ClosedRange<UInt32>] = derive()

  /// ghostty `font-codepoint-map` のキー部（`U+XXXX-U+YYYY,U+ZZZZ,…`）。単独点は `U+XXXX`。
  /// 1 行は ghostty config の行長上限（`LineIterator.MAX_LINE_SIZE` 4096B）に収まる（実測 ~1KB）。
  static let confValue: String =
    ranges.map { r in
      r.lowerBound == r.upperBound ? hex(r.lowerBound) : "\(hex(r.lowerBound))-\(hex(r.upperBound))"
    }.joined(separator: ",")

  /// 集合の照会（テスト・検証用）。
  static func contains(_ codepoint: UInt32) -> Bool {
    ranges.contains { $0.contains(codepoint) }
  }

  private static func hex(_ v: UInt32) -> String { String(format: "U+%04X", v) }

  private static func derive() -> [ClosedRange<UInt32>] {
    var out: [ClosedRange<UInt32>] = []
    var start: UInt32?
    var prev: UInt32 = 0
    for cp: UInt32 in 0...0x1FFFF {
      if Unicode.Scalar(cp)?.properties.isEmojiPresentation == true {
        if start == nil { start = cp }
        prev = cp
      } else if let s = start {
        out.append(s...prev)
        start = nil
      }
    }
    if let s = start { out.append(s...prev) }
    return out
  }
}
