import SwiftUI

/// 提案タブの右の詳細。選ばれている候補の出どころ（自動化の名前・取得の部品の名前・時刻）・本文の全体・リンク、タスクにしたとき
/// のタイトル・期限・付け先、「タスクにする」「タスクにして開く」「捨てる」のボタン。選ばれている候補が無ければ空。ボタンは欄の
/// 下端に置いてスクロールさせない——さばくキーの案内はここにしか無いので、本文が長くても隠さないため。収まらない中身だけが
/// スクロールする。
struct TaskPaletteAutomationDetail: View {
  @Bindable var model: TaskPaletteAutomationModel
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    if let proposal = model.selectedProposal {
      VStack(alignment: .leading, spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) { content(proposal) }
            .padding(.horizontal, Theme.Space.phrase)
            .padding(.top, Theme.Space.span + Theme.Space.hair)
            .padding(.bottom, Theme.Space.span)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        buttons
          .padding(.horizontal, Theme.Space.phrase)
          .padding(.top, Theme.Space.step)
          .padding(.bottom, Theme.Space.span)
      }
    } else {
      Color.clear
    }
  }

  private var text: AutomationText {
    AutomationText(l10n: l10n, today: model.today, timeZone: model.timeZone)
  }

  @ViewBuilder private func content(_ proposal: AutomationProposal) -> some View {
    // 名前は縮め、時刻は残す。
    HStack(spacing: Theme.Space.note + 1) {
      MarkGlyph(kind: .tray, width: 10, color: Color.theme.accentBright)
      let names = [model.store.shelf(of: proposal)?.name, model.sourceName(of: proposal)]
        .compactMap { $0 }
      if !names.isEmpty {
        TruncatingSlot(names.joined(separator: " · ")) {
          fontResolver.text($0, base: Theme.Typography.meta)
        }
        Text(verbatim: "·")
      }
      Text(text.stamp(proposal.item.time)).fixedSize()
    }
    .font(Font.theme.meta)
    .foregroundStyle(Color.theme.textMuted)
    quote(proposal)
      .padding(.top, Theme.Space.beat)
    if let reason = proposal.reason { why(reason, proposal) }
    Text(l10n.string(.taskPaletteAutomationAsTask))
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textMuted)
      .padding(.top, Theme.Space.bar)
    fontResolver.text(proposal.title, base: Theme.Typography.title)
      .font(Font.theme.title)
      .foregroundStyle(Color.theme.textPrimary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, Theme.Space.note)
    fields(proposal)
      .padding(.top, Theme.Space.step)
  }

  /// 「候補にした理由」と、出した判定と時刻。
  private func why(_ reason: String, _ proposal: AutomationProposal) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.tick) {
      Text(l10n.string(.taskPaletteAutomationReason))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
      fontResolver.text(reason, base: Theme.Typography.workspaceName)
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textPrimary)
        .lineSpacing(Self.reasonLeading)
        .fixedSize(horizontal: false, vertical: true)
      if let judge = model.store.automation(proposal.automationId)?.graph.node(proposal.partKey) {
        fontResolver.text(
          l10n.format(
            .taskPaletteAutomationProposedBy, judge.part.name, text.moment(proposal.proposedAt)),
          base: Theme.Typography.meta
        )
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.top, 14)
  }

  /// 付け先・期限・リンク。名前は描くときの今の workspace で解く。
  private func fields(_ proposal: AutomationProposal) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
      field(
        .taskPaletteAutomationFieldWorkspace,
        l10n.string(.taskPaletteFieldWorkspace) + " "
          + (model.destination(of: proposal)?.name ?? l10n.string(.taskPaletteNoWorkspace)))
      if let due = proposal.due {
        field(
          .taskPaletteAutomationFieldDue,
          TaskDueText.label(due, today: text.today, weekdays: TaskDueText.weekdays(l10n.language)))
      }
      field(.taskPaletteAutomationFieldLink, GitHubItemText.link(proposal.item.link, l10n: l10n))
    }
    .font(Font.theme.codeSmall)
  }

  private func field(_ label: L10nKey, _ value: String) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(l10n.string(label))
        .foregroundStyle(Color.theme.textMuted)
        .frame(width: 64, alignment: .leading)
      fontResolver.text(value, base: Theme.Typography.codeSmall)
        .foregroundStyle(Color.theme.textSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
    }
  }

  /// 本文の全体と「↗ <ホスト名> で開く」（クリックか ⌘O でブラウザで開く）。
  private func quote(_ proposal: AutomationProposal) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.step) {
      fontResolver.text(proposal.item.body, base: Theme.Typography.workspaceName)
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textPrimary)
        .lineSpacing(Theme.Space.tick)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        model.openLink()
      } label: {
        HStack(spacing: 5) {
          MarkGlyph(kind: .openOut, color: Color.theme.textMuted)
          Text(l10n.format(.taskPaletteAutomationOpenLink, AutomationText.host(proposal.item.link)))
        }
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
    }
    .padding(.vertical, Theme.Space.beat - 1)
    .padding(.horizontal, Theme.Space.beat + 1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Color.theme.surfaceInk.opacity(0.04)))
  }

  /// 理由の行の高さ 17（見本）に当たる行間。
  private static let reasonLeading = Theme.Typography.workspaceName.extraLeading(
    lineHeight: 17 / Theme.Typography.workspaceName.pointSize)

  /// 横に並びきらない狭い欄では縦に積む（ボタンの文字は縮めない）。
  private var buttons: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Theme.Space.step) { buttonRow }
      VStack(alignment: .leading, spacing: Theme.Space.step) { buttonRow }
    }
  }

  @ViewBuilder private var buttonRow: some View {
    TaskPaneButton(key: "↵", title: l10n.string(.taskPaletteMakeTask), primary: true) {
      model.accept()
    }
    TaskPaneButton(key: "⌘↵", title: l10n.string(.taskPaletteMakeTaskOpen)) {
      model.acceptAndOpen()
    }
    TaskPaneButton(key: "⌘⌫", title: l10n.string(.taskPaletteAutomationDismiss)) {
      model.dismiss()
    }
  }
}
