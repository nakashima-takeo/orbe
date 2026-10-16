import SwiftUI

/// 一覧の PR の札（「<PR の印> #213 レビュー待ち ✓」）。
struct TaskPullRequestBadge: View {
  let badge: GitHubItemText.PullRequestBadge
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.tick) {
      TaskLinkGlyph(kind: .pr, size: 10)
      Text("#\(badge.number)").foregroundStyle(Color.theme.textPrimary)
      if let phase = badge.phase {
        Text(GitHubItemText.phaseText(phase, l10n.language))
          .foregroundStyle(Color.theme.textMuted)
      }
      if let checks = badge.checks { TaskChecksMark.text(checks) }
    }
    .font(Font.theme.meta)
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, Theme.Space.note)
    .frame(height: TaskPaletteRowMetrics.badge)
    .background(RoundedRectangle(cornerRadius: Theme.Radius.sm + 1).fill(Color.theme.tintAccent))
  }
}

/// 札（提案の行の期限・右の欄の開いた workspace）。
struct TaskPaletteBadge: View {
  let text: String
  let foreground: Color
  let fill: Color

  var body: some View {
    Text(text).lineLimit(1)
      .font(Font.theme.meta)
      .foregroundStyle(foreground)
      .fixedSize()
      .padding(.horizontal, Theme.Space.note)
      .frame(height: TaskPaletteRowMetrics.badge)
      .background(RoundedRectangle(cornerRadius: Theme.Radius.sm + 1).fill(fill))
  }
}
