import SwiftUI

/// 器の chrome（ヘッダ・セグメント・一文・フッターヒントなど、リスト以外の常設スロット）の合算高。
/// カードがリスト部の上限を「窓が許した高さ − chrome」で決めるために、スロットから器へ遡上させる。
/// 縮約は sum（スロットは互いに積み上がるため）。`PaletteCard` と `DispatchCard` が共有する。
struct ChromeHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}
