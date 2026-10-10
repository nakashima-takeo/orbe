import SwiftUI

/// ボードの自動追加の一覧（左）。1 行に点・名前・いつ・前回の結果。行のクリックで選び、ポインタが乗っただけでは選択を動かさない
/// ——ボードは常に出ている画面で、ポインタが横切るたびに詳細が替わるのを避けるため。高さは行に合わせ、収まらなければ
/// 中でスクロールする。
struct BoardIntakeList: View {
  @Bindable var model: BoardIntakeModel
  let text: IntakeText
  let maxHeight: CGFloat

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          ForEach(model.standings) { standing in
            BoardIntakeRow(
              standing: standing, text: text, selected: standing.id == model.list.selectedID
            )
            .id(standing.id)
            .onTapGesture { model.tap(standing.id) }
          }
        }
      }
      .frame(maxHeight: maxHeight)
      .fixedSize(horizontal: false, vertical: true)
      .scrollIndicators(.automatic)
      .onChange(of: model.list.scrollTarget) { _, target in
        guard let target else { return }
        proxy.scrollTo(target.id)
      }
    }
    .background(Color(nsColor: Theme.Glass.surface(.help)))
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.card)
        .strokeBorder(Color.theme.borderInk.opacity(0.09), lineWidth: Theme.Stroke.hairline))
  }
}

/// 一覧の 1 行。点・名前・右端の色と文は、すべて立ち位置から読む。
struct BoardIntakeRow: View {
  let standing: BoardIntakeStanding
  let text: IntakeText
  let selected: Bool
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(spacing: Theme.Space.beat + Theme.Space.hair) {
      Circle()
        .fill(dot)
        .frame(width: Theme.Layout.boardDot, height: Theme.Layout.boardDot)
      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        fontResolver.text(standing.intake.definition.name, base: Theme.Typography.title)
          .font(Font.theme.title)
          .foregroundStyle(
            standing.intake.paused ? Color.theme.textMuted : Color.theme.textPrimary
          )
          .padding(.vertical, Self.halfLeading(Theme.Typography.title))
        Text(when)
          .font(Font.theme.workspaceName)
          .foregroundStyle(Color.theme.textSecondary)
          .padding(.vertical, Self.halfLeading(Theme.Typography.workspaceName))
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(mark.label)
        .font(Font.theme.workspaceName)
        .foregroundStyle(mark.color)
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.vertical, Theme.Space.note)
    .padding(.horizontal, Theme.Space.bar)
    .frame(minHeight: Theme.Layout.boardRowMinHeight)
    .background(selected ? Color.theme.selectionFill : Color.clear)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color.theme.borderInk.opacity(0.05))
        .frame(height: Theme.Stroke.hairline)
    }
    .contentShape(Rectangle())
  }

  private static func halfLeading(_ font: NSFont) -> CGFloat {
    font.extraLeading(lineHeight: Theme.Typography.lineBoardRow) / 2
  }

  /// 「30 分ごと · 次 17:00」。止めていれば次を出さない。
  private var when: String {
    let when = text.when(standing.intake.definition.when)
    guard let next = standing.next else { return when }
    return when + " · " + text.next(next)
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
    case .running: (l10n.string(.intakeRunning), Color.theme.accentBright)
    case .paused: (l10n.string(.intakePaused), Color.theme.textMuted)
    case .neverRan: (l10n.string(.intakeNeverRan), Color.theme.textMuted)
    case .failed(let run): (text.outcome(run), Color.theme.danger)
    case .ran(let run): (text.outcome(run), Color.theme.textSecondary)
    }
  }
}
