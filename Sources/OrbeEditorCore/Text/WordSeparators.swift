import Foundation

/// VS Code の既定の区切り文字（`USUAL_WORD_SEPARATORS`）。語の規則（出現の強調・面の語の移動と削除）が読む唯一の定義。
public enum WordSeparators {
  public static let characters = "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?"
  public static let units: Set<UInt16> = Set(characters.utf16)
}
