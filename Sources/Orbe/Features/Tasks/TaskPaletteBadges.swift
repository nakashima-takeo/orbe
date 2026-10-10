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
    .frame(height: TaskPaletteRowMetrics.firstLine)
    .background(RoundedRectangle(cornerRadius: Theme.Radius.sm + 1).fill(Color.theme.tintAccent))
  }
}

/// 行の札（優先度・期限・待ち・workspace）。
struct TaskPaletteBadge: View {
  var symbol: String?
  let text: String
  let foreground: Color
  let fill: Color
  var capsule = false
  /// 文字の上限幅（超えれば末尾を省略する）。nil は全部出す。
  var maxWidth: CGFloat?

  var body: some View {
    HStack(spacing: Theme.Space.tick) {
      if let symbol {
        Image(systemName: symbol).font(.system(size: 8, weight: .medium))
      }
      Text(text).lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: maxWidth, alignment: .leading)
    }
    .font(Font.theme.meta)
    .foregroundStyle(foreground)
    .fixedSize()
    .padding(.horizontal, capsule ? Theme.Space.step : Theme.Space.note)
    .frame(height: TaskPaletteRowMetrics.firstLine)
    .background(
      RoundedRectangle(cornerRadius: capsule ? Theme.Radius.pill : Theme.Radius.sm + 1)
        .fill(fill))
  }
}
