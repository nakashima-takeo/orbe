import OrbeSessionLog
import SwiftUI

/// 終わり方のバッジ（語で語る。色だけで意味を運ばない）。ヘッダピルと同じ小ピルの描き方。
private struct CloseOriginBadge: View {
  let origin: SessionEvent.CloseOrigin
  @Environment(\.localization) private var l10n

  var body: some View {
    Text(l10n.string(Self.key(origin)))
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textMuted)
      .padding(.horizontal, Theme.Space.step)
      .padding(.vertical, Theme.Space.hair)
      .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Color.theme.smallPillFill))
  }

  private static func key(_ origin: SessionEvent.CloseOrigin) -> L10nKey {
    switch origin {
    case .gesture: return .closedAgentsOriginGesture
    case .process: return .closedAgentsOriginProcess
    case .agent: return .closedAgentsOriginAgent
    case .controlAPI: return .closedAgentsOriginControlAPI
    case .unresolved: return .closedAgentsOriginUnresolved
    }
  }
}

/// 閉じた時刻からの経過（1 秒周期で自走。Attention の経過時間と同じ表記）。
private struct ElapsedSince: View {
  let date: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      Text(AttentionSnapshot.elapsedLabel(from: date, to: context.date))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
    }
  }
}

/// 閉じたセッション 1 件の 2 段行（`AttentionRowView` と同じ骨格）。
/// 上段: CLI 名 / `›` / root 相対 cwd（省略）/ 右端 終わり方バッジ・経過時間。下段（reason があるときだけ）: 理由。
struct ClosedAgentRowView: View {
  let item: ClosedAgentItem

  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Space.step) {
        fontResolver.text(item.command, base: Theme.Typography.workspaceName)
          .font(Font.theme.workspaceName)
          .foregroundStyle(Color.theme.textPrimary)
          .lineLimit(1)
          .layoutPriority(1)
        Text("›")
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
        fontResolver.text(
          TabTitle.derive(pwd: item.cwd, root: item.rootPath), base: Theme.Typography.chrome
        )
        .font(Font.theme.chrome)
        .foregroundStyle(Color.theme.textSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
        Spacer(minLength: Theme.Space.step)
        CloseOriginBadge(origin: item.origin)
        ElapsedSince(date: item.closedAt)
      }
      if let reason = item.reason {
        fontResolver.text(reason, base: Theme.Typography.chrome)
          .font(Font.theme.chrome)
          .foregroundStyle(Color.theme.textMuted)
          .lineLimit(1)
          .padding(.top, Theme.Space.tick)
          .padding(.bottom, Theme.Space.hair)
          .padding(.leading, Theme.Space.span)
      }
    }
    .padding(.vertical, Theme.Space.hair)
  }
}

/// 2 件以上の群の 2 段行。上段: 件数 / `›` / 終わり方バッジ / 右端 経過時間。下段: 各 cwd を `, ` で連結。
struct ClosedAgentGroupRowView: View {
  let group: ClosedAgentGroup

  @Environment(\.chromeFontResolver) private var fontResolver
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Space.step) {
        fontResolver.text(
          l10n.format(.closedAgentsGroupCount, group.items.count),
          base: Theme.Typography.workspaceName
        )
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
        Text("›")
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
        CloseOriginBadge(origin: group.origin)
        Spacer(minLength: Theme.Space.step)
        ElapsedSince(date: group.at)
      }
      fontResolver.text(
        group.items.map { TabTitle.derive(pwd: $0.cwd, root: $0.rootPath) }
          .joined(separator: ", "),
        base: Theme.Typography.chrome
      )
      .font(Font.theme.chrome)
      .foregroundStyle(Color.theme.textMuted)
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.top, Theme.Space.tick)
      .padding(.bottom, Theme.Space.hair)
      .padding(.leading, Theme.Space.span)
    }
    .padding(.vertical, Theme.Space.hair)
  }
}
