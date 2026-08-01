import SwiftUI

/// 選択可能な行の共通表現（§5「選択は tint 塗り」）。
/// - selected: `selectionFill` の淡塗り（radius 8）
/// ホバーは独立着色せず、開始のみ `onHoverEnter` で通知する（呼び出し側が `selected` を追従させる）。
/// これにより着色行は常に `selected` の 1 つに保たれる。
/// Palette 行が共有する土台。行密度は §5 Palette row 契約（padding 5×10・radius 8）。
struct SelectableRow<Content: View>: View {
  let selected: Bool
  let action: () -> Void
  /// ホバー開始（enter）のみ通知する。終了では何もしない（選択はその行に残す）。
  var onHoverEnter: () -> Void = {}
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .padding(.vertical, 5)
      .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .fill(rowFill)
      )
      .contentShape(Rectangle())
      .onTapGesture(perform: action)
      .onHover { if $0 { onHoverEnter() } }
  }

  private var rowFill: Color {
    selected ? Color.theme.selectionFill : .clear
  }
}
