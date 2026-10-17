import SwiftUI

/// 提案タブの右の詳細。選んでいる提案の出どころ（受信名と時刻）・本文の全体・リンク、タスクにしたときのタイトル・期限・付け先、
/// 「タスクにする」「タスクにして開く」「捨てる」のボタン。収まらなければ欄ごとスクロールし、収まる間はボタンを下端へ押す。
struct TaskPaletteAutomationDetail: View {
  @Bindable var model: TaskPaletteAutomationModel
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    if let proposal = model.selectedProposal {
      GeometryReader { geometry in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            content(proposal)
            Spacer(minLength: Theme.Space.span)
            buttons
          }
          .padding(.horizontal, Theme.Space.phrase)
          .padding(.top, Theme.Space.span + Theme.Space.hair)
          .padding(.bottom, Theme.Space.span)
          .frame(width: geometry.size.width)
          .frame(minHeight: geometry.size.height, alignment: .top)
        }
        .scrollIndicators(.automatic)
      }
    } else {
      Color.clear
    }
  }

  private var text: AutomationText {
    AutomationText(l10n: l10n, today: model.today, timeZone: model.timeZone)
  }

  @ViewBuilder private func content(_ proposal: AutomationProposal) -> some View {
    // 受信名は縮め、時刻は残す。
    HStack(spacing: Theme.Space.note + 1) {
      Image(systemName: "tray.and.arrow.down")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.theme.accentBright)
      if let name = model.store.shelf(of: proposal)?.name {
        TruncatingSlot(name) { fontResolver.text($0, base: Theme.Typography.meta) }
        Text("·")
      }
      Text(text.moment(proposal.item.time)).fixedSize()
    }
    .font(Font.theme.meta)
    .foregroundStyle(Color.theme.textMuted)
    quote(proposal)
      .padding(.top, Theme.Space.beat)
    Text(l10n.string(.taskPaletteAutomationAsTask))
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textMuted)
      .padding(.top, Theme.Space.span)
    fontResolver.text(proposal.title, base: Theme.Typography.title)
      .font(Font.theme.title)
      .foregroundStyle(Color.theme.textPrimary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, Theme.Space.note)
    if let due = proposal.due {
      Text(text.due(due))
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textSecondary)
        .padding(.top, Theme.Space.note)
    }
    Text(
      l10n.string(.taskPaletteFieldWorkspace) + " "
        + (model.destination(of: proposal)?.name ?? l10n.string(.taskPaletteNoWorkspace))
    )
    .font(Font.theme.workspaceName)
    .foregroundStyle(Color.theme.textSecondary)
    .lineLimit(1)
    .truncationMode(.tail)
    .padding(.top, Theme.Space.note)
  }

  /// 本文の全体と「↗ <ホスト名> で開く」（クリックか ⌘O でブラウザで開く）。
  private func quote(_ proposal: AutomationProposal) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.note) {
      fontResolver.text(proposal.item.body, base: Theme.Typography.workspaceName)
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textPrimary)
        .lineSpacing(Theme.Space.tick)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        model.openLink()
      } label: {
        Text(
          "↗ "
            + l10n.format(.taskPaletteAutomationOpenLink, AutomationText.host(proposal.item.link))
        )
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
