import SwiftUI

/// 選んだ自動化の詳細（右の欄）。見出し（名前・前回・注記・次回）と、左に地図と実行履歴・右に選んだ部品のカードの欄。カードの欄は
/// 部品が選ばれていない間（一覧に居る間）も空のまま幅を保つ——⇥ のたびに地図の幅が変わらないため。地図に残る幅が
/// `mapMinWidth` に満たなければカードを地図の下（実行履歴の上）へ回す。長ければ欄全体が縦にスクロールする（選択が替わると先頭へ
/// 戻る）。
struct BoardAutomationDetail: View {
  let model: BoardAutomationModel
  let standing: BoardAutomationStanding
  let detail: BoardAutomationDetailValue
  let card: BoardAutomationPartValue?
  let text: AutomationText
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width - Self.inset.leading - Self.inset.trailing
      let wide = width >= Self.mapMinWidth + Self.columnGap + Self.cardWidth
      ScrollView {
        VStack(alignment: .leading, spacing: Self.headingGap) {
          heading
          if wide {
            HStack(alignment: .top, spacing: Self.columnGap) {
              VStack(alignment: .leading, spacing: Self.headingGap) {
                map
                BoardAutomationHistory(detail: detail)
              }
              Group {
                if let card {
                  BoardAutomationPartCard(model: model, card: card)
                } else {
                  Color.clear
                }
              }
              .frame(width: Self.cardWidth)
            }
          } else {
            VStack(alignment: .leading, spacing: Self.headingGap) {
              map
              if let card { BoardAutomationPartCard(model: model, card: card) }
              BoardAutomationHistory(detail: detail)
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

  private var map: some View {
    BoardAutomationMapView(model: model, detail: detail, selected: model.selectedPart)
  }

  private var heading: some View {
    HStack(alignment: .top, spacing: Theme.Space.phrase) {
      VStack(alignment: .leading, spacing: Theme.Space.tick) {
        fontResolver.text(standing.name, base: Theme.Typography.title)
          .font(Font(Theme.Typography.title.monospacedWeight(.semibold)))
          .foregroundStyle(Color.theme.textPrimary)
          .frame(minHeight: Self.nameLine)
        ForEach(Array(([detail.last] + detail.notes).enumerated()), id: \.offset) { _, line in
          fontResolver.text(line, base: Theme.Typography.codeSmall)
            .font(Font.theme.codeSmall)
            .foregroundStyle(Color.theme.textMuted)
            .frame(minHeight: Self.lastLine)
        }
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
  private static let cardWidth: CGFloat = 380
  private static let upcomingLine: CGFloat = 20
  /// 名前と前回の 1 行の行箱（見本の描画の、日本語の字の行箱）。
  private static let nameLine: CGFloat = 21
  private static let lastLine: CGFloat = 17
  /// 地図に残す幅の下限。これに満たなければカードを地図の下へ回す。
  private static let mapMinWidth: CGFloat = 420
}

/// 詳細の欄の見出し（「流れ」「実行履歴」「この部品の回」）。右に欄ごとの添え物を下端に揃えて置き、下に罫線を引き、罫線の下に
/// `below` の余白を空ける。
struct BoardSectionHeader<Trailing: View>: View {
  let title: L10nKey
  var below: CGFloat = 8
  @ViewBuilder let trailing: Trailing
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(alignment: .lastTextBaseline, spacing: Theme.Space.beat) {
      Text(l10n.string(title))
        .font(Font(Theme.Typography.caption.monospacedWeight(.semibold)))
        .foregroundStyle(Color.theme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      trailing
    }
    .font(Font.theme.codeSmall)
    .foregroundStyle(Color.theme.textMuted)
    .lineLimit(1)
    .padding(.bottom, 6 + Theme.Stroke.hairline)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
    }
    .padding(.bottom, below)
  }
}
