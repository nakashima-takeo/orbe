import SwiftUI

/// 選んだ自動化の詳細（右の欄）。見出し（名前・前回・次回）と、左に流れ・右に実行履歴。幅が足りなければ実行履歴を流れの下へ
/// 回す——一覧と実行履歴の幅は固定なので、狭い窓で流れの原文が読めない幅まで潰れないため。長ければ欄全体が縦にスクロール
/// する（選択が替わると先頭へ戻る）。
struct BoardAutomationDetail: View {
  let standing: BoardAutomationStanding
  let summary: BoardAutomationSummary
  let text: AutomationText
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width - Self.inset.leading - Self.inset.trailing
      let wide = width >= Self.flowMinWidth + Self.columnGap + BoardAutomationHistory.width
      ScrollView {
        VStack(alignment: .leading, spacing: Self.headingGap) {
          heading
          if wide {
            HStack(alignment: .top, spacing: Self.columnGap) {
              BoardAutomationFlowView(summary: summary)
              BoardAutomationHistory(summary: summary).frame(width: BoardAutomationHistory.width)
            }
          } else {
            VStack(alignment: .leading, spacing: Self.headingGap) {
              BoardAutomationFlowView(summary: summary)
              BoardAutomationHistory(summary: summary)
            }
          }
        }
        .padding(Self.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .id(standing.id)
      .scrollIndicators(.automatic)
    }
  }

  private var heading: some View {
    HStack(alignment: .top, spacing: Theme.Space.bar) {
      VStack(alignment: .leading, spacing: Theme.Space.tick) {
        fontResolver.text(standing.name, base: Theme.Typography.title)
          .font(Font(Theme.Typography.title.monospacedWeight(.semibold)))
          .foregroundStyle(Color.theme.textPrimary)
          .frame(minHeight: Self.nameLine)
        Text(summary.last)
          .font(Font.theme.codeSmall)
          .foregroundStyle(Color.theme.textMuted)
          .frame(minHeight: Self.lastLine)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(upcoming)
        .font(Font.theme.codeSmall)
        .foregroundStyle(Color.theme.textSecondary)
        .frame(height: Self.upcomingLine)
        .fixedSize()
    }
  }

  /// 「次回 16:50」。止めていれば「停止中」。
  private var upcoming: String {
    if standing.paused { return l10n.string(.automationPaused) }
    return standing.next.map(text.next) ?? ""
  }

  private static let inset = EdgeInsets(top: 20, leading: 32, bottom: 20, trailing: 32)
  private static let headingGap: CGFloat = 22
  private static let columnGap: CGFloat = 40
  private static let upcomingLine: CGFloat = 20
  /// 名前と前回の 1 行の行箱（見本の描画の、日本語の字の行箱）。
  private static let nameLine: CGFloat = 21
  private static let lastLine: CGFloat = 17
  /// 流れの原文の箱が読める幅。これに満たなければ実行履歴を下へ回す。
  private static let flowMinWidth: CGFloat = 420
}

/// 詳細の欄の見出し（「流れ」「実行履歴」）。右に欄ごとの添え物を置き、下に罫線を引く。
struct BoardSectionHeader<Trailing: View>: View {
  let title: L10nKey
  @ViewBuilder let trailing: Trailing
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: 10) {
      Text(l10n.string(title))
        .font(Font(Theme.Typography.caption.monospacedWeight(.semibold)))
        .foregroundStyle(Color.theme.textSecondary)
        .frame(minHeight: 17)
      Spacer(minLength: 0)
      trailing
    }
    .font(Font.theme.codeSmall)
    .padding(.bottom, 10 + Theme.Stroke.hairline)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.theme.borderInk.opacity(0.06)).frame(height: Theme.Stroke.hairline)
    }
  }
}
