import SwiftUI

/// 詳細の「実行履歴」。見出しの右に直近の回の帯（古い回が左）、下に新しい順の 1 行ずつ。失敗の行だけは理由の全文を赤で
/// 折り返す——ボードで失敗の理由を読めるのはここだけで、直すかどうかを決める材料になるため。
struct BoardAutomationHistory: View {
  let summary: BoardAutomationSummary
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      BoardSectionHeader(title: .boardAutomationRuns) {
        HStack(spacing: Theme.Space.hair) {
          ForEach(Array(summary.strip.enumerated()), id: \.offset) { _, tone in
            RoundedRectangle(cornerRadius: 1)
              .fill(color(tone, strip: true))
              .frame(width: Theme.Space.tick, height: 10)
          }
        }
      }
      .padding(.bottom, Theme.Space.step)
      if summary.runs.isEmpty {
        Text(l10n.string(.automationNeverRan))
          .foregroundStyle(Color.theme.textMuted)
          .frame(height: Self.line)
      } else {
        let column =
          summary.runs.map { fontResolver.width($0.at, base: Theme.Typography.codeSmall) }
          .max()?.rounded(.up) ?? 0
        ForEach(Array(summary.runs.enumerated()), id: \.offset) { _, run in
          HStack(alignment: .top, spacing: Self.columnGap) {
            Text(run.at)
              .foregroundStyle(Color.theme.textSecondary)
              .frame(width: column, height: Self.line, alignment: .leading)
            result(run)
          }
        }
      }
    }
    .font(Font.theme.codeSmall)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func result(_ run: BoardRunLine) -> some View {
    let text = fontResolver.text(run.result, base: Theme.Typography.codeSmall)
      .foregroundStyle(color(run.tone, strip: false))
    if run.tone == .failed {
      text
        .lineSpacing(Self.wrapLeading)
        .padding(.vertical, Self.wrapLeading / 2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      text
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, minHeight: Self.line, alignment: .leading)
    }
  }

  private func color(_ tone: BoardRunTone, strip: Bool) -> Color {
    switch tone {
    case .produced: strip ? Color.theme.accentPrimary : Color.theme.textPrimary
    case .quiet: strip ? Color.theme.editorGhost : Color.theme.textMuted
    case .failed: Color.theme.danger
    }
  }

  static let width: CGFloat = 300
  private static let line: CGFloat = 24
  private static let columnGap: CGFloat = 14
  /// 1 行 24 に当たる行間（折り返した失敗の理由も、1 行の行と同じ間隔で並ぶ）。
  private static let wrapLeading = Theme.Typography.codeSmall.extraLeading(
    lineHeight: line / Theme.Typography.codeSmall.pointSize)
}
