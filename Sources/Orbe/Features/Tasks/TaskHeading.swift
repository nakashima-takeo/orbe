import SwiftUI

/// 主の結び付きが無いタスクの右の欄の見出し（「タスク」。入力欄から今足したなら「タスク · 今 ⌘⇧X から足した」）。
struct TaskHeading: View {
  let justAdded: Bool
  @Environment(\.localization) private var l10n

  var body: some View {
    Text(
      justAdded
        ? l10n.string(.taskPaletteHeadingTask) + " · " + l10n.string(.taskPaletteAddedHeading)
        : l10n.string(.taskPaletteHeadingTask)
    )
    .font(Font.theme.meta)
    .foregroundStyle(Color.theme.textMuted)
    .lineLimit(1)
  }
}
