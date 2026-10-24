import SwiftUI

/// 選んだ自動化の詳細（右の欄）。見出し（名前・「通知」の段・次回・直近の実行の帯）と、左に地図・右に選んだノードのカードの欄。
/// カードの欄はノードが選ばれていない間（一覧に居る間・「通知」の段）も空のまま幅を保つ——段を移るたびに地図の幅が変わらないため。
/// 地図に残る幅が `mapMinWidth` に満たなければカードを地図の下へ回す。長ければ欄全体が縦にスクロールする（選択が替わると
/// 先頭へ戻る）。サブメニュー「通知」を開くときは「通知」の行を見える範囲へ引き寄せる——外にあるまま開くと、見えない
/// メニューがキーを奪うため。
struct BoardAutomationDetail: View {
  let model: BoardAutomationModel
  let standing: BoardAutomationStanding
  let detail: BoardAutomationDetailValue
  let card: BoardAutomationNodeValue?
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width - Self.inset.leading - Self.inset.trailing
      let wide = width >= Self.mapMinWidth + Self.columnGap + Self.cardWidth
      ScrollViewReader { proxy in
        scroll(wide: wide)
          .onChange(of: model.notifyCursor != nil) { was, now in
            if !was, now { proxy.scrollTo(BoardAutomationModel.MapStop.notify) }
          }
      }
    }
  }

  private func scroll(wide: Bool) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Self.headingGap) {
        heading
        if wide {
          HStack(alignment: .top, spacing: Self.columnGap) {
            map
            Group {
              if let card {
                BoardAutomationNodeCard(model: model, card: card)
              } else {
                Color.clear
              }
            }
            .frame(width: Self.cardWidth)
          }
        } else {
          VStack(alignment: .leading, spacing: Self.headingGap) {
            map
            if let card { BoardAutomationNodeCard(model: model, card: card) }
          }
        }
      }
      .padding(Self.inset)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .id(standing.id)
    .scrollIndicators(.automatic)
    .transformAnchorPreference(key: BoardAutomationNotifyAnchor.self, value: .bounds) {
      $0.viewport = $1
    }
  }

  private var map: some View {
    BoardAutomationMapView(model: model, detail: detail, selected: model.selectedNodeId)
  }

  private var heading: some View {
    HStack(alignment: .top, spacing: Theme.Space.phrase) {
      VStack(alignment: .leading, spacing: Theme.Space.tick) {
        fontResolver.text(standing.title(l10n), base: Theme.Typography.title)
          .font(Font(Theme.Typography.title.monospacedWeight(.semibold)))
          .foregroundStyle(Color.theme.textPrimary)
          .frame(minHeight: Self.nameLine)
        notifyRow
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 6) {
        upcoming
          .font(Font.theme.codeSmall)
          .frame(height: Self.upcomingLine)
        HStack(spacing: Theme.Space.step) {
          Text(l10n.string(.boardRecentRuns))
            .font(Font.theme.codeSmall)
            .foregroundStyle(Color.theme.textMuted)
          BoardRunStrip(tones: detail.strip)
        }
      }
      .fixedSize()
    }
  }

  /// 見出しの「通知：メニューバー」。地図の先頭の段で、選んでいる間は濃い地。クリックでその段を選んで 3 択を開く。
  private var notifyRow: some View {
    Text(detail.notify)
      .font(Font.theme.codeSmall)
      .foregroundStyle(Color.theme.textMuted)
      .frame(minHeight: Self.lastLine)
      .padding(.horizontal, Self.notifyInset)
      .background(
        model.selectedMapStop == .notify ? Color.theme.selectionFill : Color.clear,
        in: RoundedRectangle(cornerRadius: 4)
      )
      .padding(.horizontal, -Self.notifyInset)
      .contentShape(Rectangle())
      .onTapGesture { model.tapNotify() }
      .id(BoardAutomationModel.MapStop.notify)
      .anchorPreference(key: BoardAutomationNotifyAnchor.self, value: .bounds) {
        BoardAutomationNotifyAnchor(row: $0)
      }
  }

  /// 「次回 16:50」。止めていれば停止の印と「一時停止中」。
  @ViewBuilder private var upcoming: some View {
    if standing.paused {
      HStack(spacing: 5) {
        MarkGlyph(kind: .paused, color: Color.theme.textMuted)
        Text(l10n.string(.automationPaused))
      }
      .foregroundStyle(Color.theme.textMuted)
    } else {
      Text(detail.next ?? "").foregroundStyle(Color.theme.textSecondary)
    }
  }

  private static let inset = EdgeInsets(top: 20, leading: 32, bottom: 20, trailing: 32)
  private static let headingGap: CGFloat = 22
  private static let columnGap: CGFloat = 40
  private static let cardWidth: CGFloat = 380
  private static let upcomingLine: CGFloat = 20
  /// 名前と通知の 1 行の行箱（見本の描画の、日本語の字の行箱）。
  private static let nameLine: CGFloat = 21
  private static let lastLine: CGFloat = 17
  /// 「通知」の段の選択の地を字の外へ広げる幅。
  private static let notifyInset: CGFloat = 4
  /// 地図に残す幅の下限。これに満たなければカードを地図の下へ回す。
  private static let mapMinWidth: CGFloat = 480
}

/// 直近の回の帯。出した回は高い棒（強調色）、何もしなかった回は低い棒（沈んだ色）、失敗は赤の斜めの十字——色だけでなく形でも
/// 見分ける。古い回が左。
struct BoardRunStrip: View {
  let tones: [BoardRunTone]

  var body: some View {
    HStack(spacing: Theme.Space.hair) {
      ForEach(Array(tones.enumerated()), id: \.offset) { _, tone in
        switch tone {
        case .produced:
          RoundedRectangle(cornerRadius: 1).fill(Color.theme.accentBright).frame(
            width: 4, height: 12)
        case .quiet:
          RoundedRectangle(cornerRadius: 1).fill(Color.theme.editorGhost).frame(width: 4, height: 4)
        case .failed:
          MarkGlyph(kind: .bandFailure, color: Color.theme.danger)
        }
      }
    }
    .frame(height: 12)
  }
}

/// 詳細の欄の見出し（「流れ」「このノードの実行履歴」「前回の報告」）。右に欄ごとの添え物を下端に揃えて置き、下に罫線を引き、
/// 罫線の下に `below` の余白を空ける。
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

/// 定義を読めない自動化の詳細（右の欄）。名前と理由と「修正を依頼」だけを出す——地図とカードは定義から組むので出せない。
struct BoardAutomationUnreadableDetail: View {
  let model: BoardAutomationModel
  let standing: BoardAutomationStanding
  let reason: String
  let text: AutomationText
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.phrase) {
      fontResolver.text(standing.title(l10n), base: Theme.Typography.title)
        .font(Font(Theme.Typography.title.monospacedWeight(.semibold)))
        .foregroundStyle(Color.theme.textPrimary)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        BoardRunMarkGlyph(mark: .failure)
        fontResolver.text(text.unreadable(reason), base: Theme.Typography.codeSmall)
          .font(Font.theme.codeSmall)
          .foregroundStyle(Color.theme.danger)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button {
        model.draftFixOfUnreadable(l10n: l10n)
      } label: {
        Text(l10n.string(.boardNodeAskFix))
          .font(Font.theme.workspaceName)
          .foregroundStyle(Color.theme.textPrimary)
          .padding(.horizontal, 10)
          .frame(height: 26)
          .background(
            Color.theme.surfaceInk.opacity(0.06),
            in: RoundedRectangle(cornerRadius: Theme.Radius.row)
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
    }
    .padding(EdgeInsets(top: 20, leading: 32, bottom: 20, trailing: 32))
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
