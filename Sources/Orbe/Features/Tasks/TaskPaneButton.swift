import SwiftUI

/// GitHub タブの右の欄のボタン（「↵ タスクにする」）。`wide` は欄の幅いっぱいに広げ、文字を左に寄せる。
struct TaskPaneButton: View {
  let key: String
  let title: String
  var primary = false
  var wide = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Space.step) {
        Text(key).foregroundStyle(primary ? Color.theme.accentBright : Color.theme.textMuted)
        Text(title).foregroundStyle(Color.theme.textPrimary)
        if wide { Spacer(minLength: 0) }
      }
      .font(Font.theme.taskText)
      .lineLimit(1)
      .fixedSize(horizontal: !wide, vertical: !wide)
      .padding(.horizontal, Theme.Space.beat)
      .frame(height: 34)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.row)
          .fill(primary ? Color.theme.tintAccent : Color.theme.surfaceInk.opacity(0.06))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
  }
}
