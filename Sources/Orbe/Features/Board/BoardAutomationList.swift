import SwiftUI

/// ボードの自動化の一覧（左の欄）。見出し「自動化 N」と行。行のクリックで選び、ポインタが乗っただけでは選択を動かさない
/// ——ボードは常に出ている画面で、ポインタが横切るたびに詳細が替わるのを避けるため。収まらなければ行が中でスクロールする。
struct BoardAutomationList: View {
  @Bindable var model: BoardAutomationModel
  let standings: [BoardAutomationStanding]
  let text: AutomationText
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
    .transformAnchorPreference(key: BoardAutomationNotifyAnchor.self, value: .bounds) {
      $0.list = $1
    }
  }

  private var rows: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          ForEach(standings) { standing in
            BoardAutomationRow(
              standing: standing, summary: model.summary(standing.id, text: text),
              selected: model.list.selectedID == .automation(standing.id)
            )
            .id(BoardAutomationModel.Stop.automation(standing.id))
            .onTapGesture { model.tap(standing.id) }
            .anchorPreference(key: BoardAutomationNotifyAnchor.self, value: .bounds) {
              model.list.selectedID == .automation(standing.id) ? .init(row: $0) : .init()
            }
          }
        }
        .padding(.horizontal, Theme.Space.note)
      }
      .scrollIndicators(.automatic)
      .transformAnchorPreference(key: BoardAutomationNotifyAnchor.self, value: .bounds) {
        $0.viewport = $1
      }
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

/// 一覧の 1 行。上段に点・名前・右端の文、下段に出力先の種類といつ。点・名前・右端の色と種類は立ち位置から、文は読み替えから
/// 読む。
struct BoardAutomationRow: View {
  let standing: BoardAutomationStanding
  let summary: BoardAutomationSummary?
  let selected: Bool
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(spacing: Self.gap) {
      Circle()
        .fill(dot)
        .frame(width: Self.dot, height: Self.dot)
      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.step) {
          fontResolver.text(standing.name, base: Theme.Typography.code)
            .font(Font.theme.code)
            .foregroundStyle(standing.paused ? Color.theme.textMuted : Color.theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.nameLine)
          Text(mark.label)
            .font(Font.theme.codeSmall)
            .foregroundStyle(mark.color)
            .fixedSize()
        }
        HStack(spacing: Theme.Space.beat) {
          Text(summary?.output ?? "").foregroundStyle(Color.theme.kbKeyText)
          Text(summary?.when ?? "")
        }
        .font(Font.theme.codeSmall)
        .foregroundStyle(Color.theme.textMuted)
        .frame(height: Self.whenLine)
      }
      .lineLimit(1)
      .truncationMode(.tail)
    }
    .padding(.horizontal, Self.inset)
    .frame(height: Self.height)
    .background(
      selected ? Color.theme.selectionFill : Color.clear,
      in: RoundedRectangle(cornerRadius: Self.radius)
    )
    .contentShape(Rectangle())
  }

  private var dot: Color {
    switch standing.group {
    case .failing: Color.theme.danger
    case .paused: Color.theme.textMuted
    case .active: Color.theme.accentBright
    }
  }

  private var mark: (label: String, color: Color) {
    switch standing.mark {
    case .running: (l10n.string(.automationRunning), Color.theme.accentBright)
    case .paused: (l10n.string(.automationPaused), Color.theme.textMuted)
    case .neverRan: (l10n.string(.automationNeverRan), Color.theme.textMuted)
    case .ran(let tone):
      (summary?.mark ?? "", tone == .failed ? Color.theme.danger : Color.theme.textSecondary)
    }
  }

  private static let height: CGFloat = 46
  private static let inset: CGFloat = 10
  private static let gap: CGFloat = 10
  private static let dot: CGFloat = 6
  private static let radius: CGFloat = 6
  private static let nameLine: CGFloat = 18
  private static let whenLine: CGFloat = 16
}
