import SwiftUI

/// ボードの自動化の一覧（左の欄）。見出し「自動化 N」と行。行のクリックで選び、ポインタが乗っただけでは選択を動かさない
/// ——ボードは常に出ている画面で、ポインタが横切るたびに詳細が替わるのを避けるため。収まらなければ行が中でスクロールする。
struct BoardAutomationList: View {
  @Bindable var model: BoardAutomationModel
  let standings: [BoardAutomationStanding]
  let text: AutomationText
  let now: Date
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Space.step) {
        Text(l10n.string(.boardAutomationTitle))
          .font(Font(Theme.Typography.caption.monospacedWeight(.semibold)))
          .foregroundStyle(Color.theme.textSecondary)
        Text(verbatim: "\(standings.count)")
          .font(Font.theme.codeSmall)
          .foregroundStyle(Color.theme.textMuted)
      }
      .padding(.horizontal, Theme.Space.bar)
      .frame(height: Self.headerHeight)
      if standings.isEmpty {
        Text(l10n.string(.boardAutomationEmpty))
          .font(Font.theme.code)
          .foregroundStyle(Color.theme.textMuted)
          .padding(.horizontal, Theme.Space.bar)
      } else {
        rows
      }
    }
    .frame(width: Self.width, alignment: .topLeading)
    .frame(maxHeight: .infinity, alignment: .top)
    .padding(.trailing, Theme.Stroke.hairline)
    .background(Color.theme.surfaceInk.opacity(0.02))
    .overlay(alignment: .trailing) {
      Rectangle().fill(Color.theme.surface1).frame(width: Theme.Stroke.hairline)
    }
  }

  private var rows: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: Theme.Space.hair) {
          ForEach(standings) { standing in
            BoardAutomationRow(
              standing: standing, summary: model.summary(standing.id, text: text, now: now),
              selection: model.list.selectedID == .automation(standing.id)
                ? (model.inMap ? .parent : .focused) : nil
            )
            .id(BoardAutomationModel.Stop.automation(standing.id))
            .onTapGesture { model.tap(standing.id) }
          }
        }
        .padding(.horizontal, Theme.Space.note)
      }
      .scrollIndicators(.automatic)
      .onChange(of: model.list.scrollTarget) { _, target in
        guard let target else { return }
        proxy.scrollTo(target.id)
      }
    }
  }

  /// 右の罫線を除いた幅。
  private static let width: CGFloat = 360
  private static let headerHeight: CGFloat = 32
}

/// 一覧の 1 行。上段に名前と状態（実行中・停止中）、下段に前回の結果の印と時刻・次回。状態と結果の印は混ぜない——走っている
/// ことと前回失敗したことは別の事実で、片方がもう片方を隠さないため。状態は立ち位置から、前回と次回は読み替えから読む。選んで
/// いる行は、焦点が一覧にあれば濃い地、地図にあれば（その自動化の段を選んでいる間）薄い地。
struct BoardAutomationRow: View {
  enum Selection {
    case focused
    case parent
  }

  let standing: BoardAutomationStanding
  let summary: BoardAutomationSummary?
  let selection: Selection?
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.hair) {
      HStack(spacing: Self.gap) {
        fontResolver.text(standing.name, base: Theme.Typography.code)
          .font(Font.theme.code)
          .foregroundStyle(standing.paused ? Color.theme.textMuted : Color.theme.textPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
        state
      }
      .frame(height: Self.nameLine)
      HStack(spacing: Theme.Space.beat) {
        HStack(spacing: 5) {
          if let mark = summary?.mark { BoardRunMarkGlyph(mark: mark) }
          Text(summary?.last ?? "")
        }
        Spacer(minLength: 0)
        if let next = summary?.next { Text(next) }
      }
      .font(Font.theme.codeSmall)
      .foregroundStyle(Color.theme.textMuted)
      .frame(height: Self.whenLine)
    }
    .lineLimit(1)
    .truncationMode(.tail)
    .padding(.horizontal, Self.inset)
    .frame(height: Self.height)
    .background(fill, in: RoundedRectangle(cornerRadius: Self.radius))
    .contentShape(Rectangle())
  }

  @ViewBuilder private var state: some View {
    switch standing.state {
    case .running:
      HStack(spacing: 5) {
        StatusGlyphView(kind: .working, size: 10)
        Text(l10n.string(.automationRunning))
      }
      .font(Font.theme.codeSmall)
      .foregroundStyle(Color.theme.accentBright)
      .fixedSize()
    case .paused:
      HStack(spacing: 5) {
        MarkGlyph(kind: .paused, color: Color.theme.textMuted)
        Text(l10n.string(.automationPaused))
      }
      .font(Font.theme.codeSmall)
      .foregroundStyle(Color.theme.textMuted)
      .fixedSize()
    case nil:
      EmptyView()
    }
  }

  private var fill: Color {
    switch selection {
    case .focused: Color.theme.selectionFill
    case .parent: Color.theme.surfaceInk.opacity(0.06)
    case nil: Color.clear
    }
  }

  private static let height: CGFloat = 46
  private static let inset: CGFloat = 10
  private static let gap: CGFloat = 10
  private static let radius: CGFloat = 6
  private static let nameLine: CGFloat = 18
  private static let whenLine: CGFloat = 16
}

/// 成否の印（成功は強調色のチェック、失敗は赤の斜めの十字）。色だけでなく形で見分ける。
struct BoardRunMarkGlyph: View {
  let mark: BoardRunMark

  var body: some View {
    switch mark {
    case .success: MarkGlyph(kind: .success, color: Color.theme.accentBright)
    case .failure: MarkGlyph(kind: .failure, color: Color.theme.danger)
    }
  }
}
