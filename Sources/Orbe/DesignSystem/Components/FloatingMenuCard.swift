import SwiftUI

extension View {
  /// 浮くメニューの器（地・影・縁・角丸）。⌘⇧X の絞り込みのメニューとボードのサブメニュー「通知」が使う。
  func floatingMenuCard() -> some View {
    background(
      RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color.theme.bgBase)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .strokeBorder(Color.theme.surface2, lineWidth: Theme.Stroke.hairline))
  }
}
