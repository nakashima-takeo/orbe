import SwiftUI

/// タスクの行の agent の札（「◌ claude 12分」「▪ claude 入力待ち」）。経過は 1 分ごとに描き直し、描いた
/// 時刻から測る（`TimelineView` の予定の時刻は分の区切りに揃って、今より最大 1 分前になる）。
struct TaskAgentBadge: View {
  let agent: WorktreeAgentActivity.Agent
  @Environment(\.localization) private var l10n

  var body: some View {
    TimelineView(.everyMinute) { _ in
      HStack(spacing: Theme.Space.note) {
        StatusGlyphView(kind: agent.state == .working ? .working : .waiting, size: 10)
        Text(agent.name)
        Text(
          agent.state == .working
            ? TaskElapsedText.label(since: agent.since, now: Date(), l10n: l10n)
            : l10n.string(.taskPaletteAgentWaitingBadge))
      }
      .font(Font.theme.codeCompact)
      .foregroundStyle(TaskAgentColors.foreground(agent.state))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
      .frame(height: 20)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.pill).fill(TaskAgentColors.fill(agent.state)))
    }
  }
}

/// 詳細の agent の場所（「claude が取り掛かっている ／ working 12分 · タブ <名前>」と「↗ タブへ」）。
/// ↵ かクリックでそのタブへ移る。
struct TaskAgentDetail: View {
  let agent: WorktreeAgentActivity.Agent
  let focused: Bool
  let onGoToTab: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    TimelineView(.everyMinute) { _ in
      VStack(alignment: .leading, spacing: Theme.Space.tick) {
        HStack(spacing: Theme.Space.note) {
          StatusGlyphView(kind: agent.state == .working ? .working : .waiting, size: 11)
          Text(
            l10n.format(
              agent.state == .working ? .taskPaletteAgentWorking : .taskPaletteAgentWaiting,
              agent.name)
          )
          .font(Font.theme.taskText)
          .foregroundStyle(TaskAgentColors.foreground(agent.state))
          .lineLimit(1)
          Spacer(minLength: Theme.Space.step)
          Text("↗ " + l10n.string(.taskPaletteAgentGoToTab))
            .font(Font.theme.codeCompact)
            .foregroundStyle(Color.theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Theme.Space.step)
            .frame(height: 22)
            .background(
              RoundedRectangle(cornerRadius: Theme.Radius.sm + 1)
                .fill(Color.theme.surfaceInk.opacity(0.06)))
        }
        Text(
          [
            agent.state == .working ? "working" : "waiting",
            TaskElapsedText.label(since: agent.since, now: Date(), l10n: l10n),
            "·", l10n.format(.taskPaletteAgentTab, agent.tabTitle),
          ].joined(separator: " ")
        )
        .font(Font.theme.codeCompact)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.leading, 11 + Theme.Space.note)
      }
      .padding(.horizontal, Theme.Space.beat)
      .padding(.vertical, Theme.Space.beat)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.md)
          .fill(focused ? Color.theme.selectionFill : Color.theme.surfaceInk.opacity(0.04))
      )
      .contentShape(Rectangle())
      .onTapGesture(perform: onGoToTab)
    }
  }
}

/// agent の状態の色（作業中は青・入力待ちは黄。タブ行のグリフと同じ状態色）。
enum TaskAgentColors {
  static func foreground(_ state: WorktreeAgentState) -> Color {
    state == .working ? Color.theme.stateWorking : Color.theme.stateWaiting
  }

  static func fill(_ state: WorktreeAgentState) -> Color {
    state == .working ? Color.theme.tintWorking : Color.theme.tintWaiting
  }
}
