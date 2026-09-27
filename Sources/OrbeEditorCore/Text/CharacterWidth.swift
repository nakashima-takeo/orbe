/// 等幅の桁で数えた字の幅の目安（VS Code の `strings.isFullWidthCharacter`・`strings.isEmojiImprecise`）。全角と絵文字は
/// 2 桁、それ以外は 1 桁。
public enum CharacterWidth {
  /// 全角（CJK・かな・ハングルの音節・全角の記号）。
  public static func isFullWidth(_ codePoint: UInt32) -> Bool {
    (0x2E80...0xD7AF).contains(codePoint) || (0xF900...0xFAFF).contains(codePoint)
      || (0xFF01...0xFF5E).contains(codePoint) || (0xFFE0...0xFFE6).contains(codePoint)
  }

  /// 絵文字（おおよその範囲）。
  public static func isEmoji(_ codePoint: UInt32) -> Bool {
    (0x1F1E6...0x1F1FF).contains(codePoint) || codePoint == 8986 || codePoint == 8987
      || codePoint == 9200 || codePoint == 9203 || (9728...10175).contains(codePoint)
      || codePoint == 11088 || codePoint == 11093 || (127744...128591).contains(codePoint)
      || (128640...128764).contains(codePoint) || (128992...129008).contains(codePoint)
      || (129280...129535).contains(codePoint) || (129648...129782).contains(codePoint)
  }

  /// 字（書記素の最初の符号位置）の桁の数。
  public static func columns(_ codePoint: UInt32) -> Int {
    isFullWidth(codePoint) || isEmoji(codePoint) ? 2 : 1
  }
}
