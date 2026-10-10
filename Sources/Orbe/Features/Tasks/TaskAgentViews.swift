import SwiftUI

/// タスクの行の agent の札（「◌ claude 12分」「▪ claude 入力待ち」）。経過はその状態になった時刻から 1 分
/// ごとに描き直す（その時刻が動けば、TimelineView は新しい予定で刻み直す）。
struct TaskAgentBadge: View {
  let agent: WorktreeAgentActivity.Agent
  @Environment(\.localization) private var l10n

  var body: some View {
    TimelineView(.periodic(from: agent.since, by: 60)) { context in
      HStack(spacing: Theme.Space.tick) {
        StatusGlyphView(kind: agent.state, size: 9)
        Text(agent.name)
        Text(
          agent.state == .working
            ? TaskElapsedText.label(since: agent.since, now: context.date, l10n: l10n)
            : l10n.string(.taskPaletteAgentWaitingBadge))
      }
      .font(Font.theme.meta)
      .foregroundStyle(agent.state.stateColor)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Theme.Space.step)
      .frame(height: TaskPaletteRowMetrics.firstLine)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.pill).fill(TaskAgentColors.tint(agent.state)))
    }
  }
}

/// 右の欄の agent の場所（「claude が取り掛かっている ／ working 12分 · タブ <名前>」と「↗ タブへ」）。状態を
/// 問わず出し（完了・休止でも、続きを頼みにタブへ移れる）、↵ かクリックでそのタブへ移る。
struct TaskAgentDetail: View {
  let agent: WorktreeAgentActivity.Agent
  let focused: Bool
  let onGoToTab: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    TimelineView(.periodic(from: agent.since, by: 60)) { context in
      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        HStack(spacing: Theme.Space.note) {
          StatusGlyphView(kind: agent.state, size: 10)
          Text(l10n.format(Self.headline(agent.state), agent.name))
            .font(Font.theme.workspaceName)
            .foregroundStyle(agent.state.stateColor)
            .lineLimit(1)
          Spacer(minLength: Theme.Space.step)
          TaskGoToTabChip()
        }
        Text(
          [
            agent.state.state,
            TaskElapsedText.label(since: agent.since, now: context.date, l10n: l10n),
            "·", l10n.format(.taskPaletteAgentTab, agent.tabTitle),
          ].joined(separator: " ")
        )
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.leading, 10 + Theme.Space.note)
      }
      .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
      .padding(.vertical, Theme.Space.step)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.md)
          .fill(focused ? Color.theme.selectionFill : Color.theme.surfaceInk.opacity(0.04))
      )
      .contentShape(Rectangle())
      .onTapGesture(perform: onGoToTab)
    }
  }

  private static func headline(_ state: AgentStateIcon.Kind) -> L10nKey {
    switch state {
    case .working: .taskPaletteAgentWorking
    case .waiting: .taskPaletteAgentWaiting
    case .done: .taskPaletteAgentDone
    case .idle, .dormant: .taskPaletteAgentIdle
    }
  }
}

/// 行の札の地（状態の淡い塗り）。文字とグリフの色は状態色（`AgentStateIcon.Kind.stateColor`）。
enum TaskAgentColors {
  static func tint(_ state: AgentStateIcon.Kind) -> Color {
    switch state {
    case .working: Color.theme.tintWorking
    case .waiting: Color.theme.tintWaiting
    case .done: Color.theme.tintDone
    case .idle, .dormant: Color.theme.plainPillFill
    }
  }
}
