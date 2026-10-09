import SwiftUI

/// 受信タブの本体。左に棚、真ん中に提案の一覧、右に選んだ提案の詳細。中身に居る間は、真ん中と右をまたいで受信の中身を
/// 1 枚で出す。棚はカードの幅の 1/4 で、狭い窓では下限で止めて真ん中を縮める。
struct TaskPaletteIntakeBody: View {
  @Bindable var model: TaskPaletteIntakeModel
  let detailWidth: CGFloat

  private static let minShelfWidth: CGFloat = 176

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        TaskPaletteIntakeShelf(model: model)
          .frame(width: max(Self.minShelfWidth, geometry.size.width / 4))
        rule
        if model.place == .contents, let intake = model.selectedIntake {
          TaskPaletteIntakeContents(model: model, intake: intake)
        } else {
          TaskPaletteIntakeList(model: model)
          rule
          TaskPaletteIntakeDetail(model: model)
            .frame(width: detailWidth)
        }
      }
    }
  }

  private var rule: some View {
    Rectangle().fill(Color.theme.surface1).frame(width: Theme.Stroke.hairline)
  }
}

/// 真ん中の提案の一覧。受信を選んでいれば、頭に前回の回の要約と「中身 →」を出す。
struct TaskPaletteIntakeList: View {
  @Bindable var model: TaskPaletteIntakeModel
  @Environment(\.localization) private var l10n

  var body: some View {
    let proposals = model.proposals
    let list = model.proposalList
    VStack(alignment: .leading, spacing: 0) {
      if let intake = model.selectedIntake { headline(intake) }
      if proposals.isEmpty {
        Text(l10n.string(.taskPaletteIntakeEmpty))
          .font(Font.theme.workspaceName)
          .foregroundStyle(Color.theme.textMuted)
          .padding(.horizontal, Theme.Space.phrase)
          .padding(.vertical, Theme.Space.beat)
        Spacer(minLength: 0)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.hair) {
              ForEach(proposals) { row($0) }
            }
            .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
            .padding(.top, model.selectedIntake == nil ? Theme.Space.beat : 0)
            .padding(.bottom, Theme.Space.beat)
          }
          .scrollIndicators(.automatic)
          .onChange(of: list.scrollTarget) {
            if let id = list.scrollTarget?.id { proxy.scrollTo(id) }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// 「13:00 の回 · 9 件取得 → 新しい 4 件を判定 → 提案 2」と「中身 →」。狭い欄では要約を 2 行まで折り返す。
  private func headline(_ intake: Intake) -> some View {
    let text = IntakeText(l10n: l10n, today: model.today, timeZone: model.timeZone)
    return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.step) {
      Text(text.runHeadline(intake.runs.first))
        .foregroundStyle(
          intake.runs.first?.failure == nil ? Color.theme.textMuted : Color.theme.danger
        )
        .lineLimit(2)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: Theme.Space.step)
      Button {
        model.enterContents()
      } label: {
        Text(l10n.string(.taskPaletteIntakeContents) + " →")
          .foregroundStyle(Color.theme.textSecondary)
          .fixedSize()
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
    }
    .font(Font.theme.meta)
    .padding(.horizontal, Theme.Space.phrase)
    .padding(.vertical, Theme.Space.step)
    .frame(minHeight: 30)
    .padding(.top, Theme.Space.tick)
  }

  private func row(_ proposal: IntakeProposal) -> some View {
    TaskPaletteIntakeProposalRow(
      proposal: proposal,
      text: IntakeText(l10n: l10n, today: model.today, timeZone: model.timeZone),
      selected: model.proposalList.selectedID == proposal.id,
      focused: model.place == .proposals
    )
    .contentShape(Rectangle())
    .onTapGesture { model.tapProposal(proposal.id) }
    .onHover { if $0 { model.hoverProposal(proposal.id) } }
    .id(proposal.id)
  }
}

/// 提案の行。タイトル・期限の札・右に時刻、下に本文の先頭 1 行。提案の一覧に居ない間は、選択の地を薄くする（キーが届く
/// 場所を見せる）。
private struct TaskPaletteIntakeProposalRow: View {
  let proposal: IntakeProposal
  let text: IntakeText
  let selected: Bool
  let focused: Bool
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.tick) {
      HStack(spacing: Theme.Space.step) {
        TruncatingSlot(proposal.title) {
          fontResolver.text($0, base: Theme.Typography.workspaceName)
            .font(Font.theme.workspaceName)
            .foregroundStyle(Color.theme.textPrimary)
        }
        .layoutPriority(1)
        if let due = proposal.due {
          TaskPaletteBadge(
            text: TaskDueText.label(
              due, today: text.today, weekdays: TaskDueText.weekdays(l10n.language)),
            foreground: Color.theme.textSecondary, fill: Color.theme.plainPillFill)
        }
        Spacer(minLength: Theme.Space.step)
        Text(text.short(proposal.item.time))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .fixedSize()
      }
      fontResolver.text(Self.firstLine(proposal.item.body), base: Theme.Typography.meta)
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.vertical, Theme.Space.step + Theme.Space.hair)
    .padding(.horizontal, Theme.Space.bar - Theme.Space.hair)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(
          selected
            ? (focused ? Color.theme.selectionFill : Color.theme.surfaceInk.opacity(0.06))
            : .clear))
  }

  /// 本文の先頭 1 行（空の行は飛ばす）。
  static func firstLine(_ body: String) -> String {
    body.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
  }
}
