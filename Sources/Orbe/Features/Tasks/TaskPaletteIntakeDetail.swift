import SwiftUI

/// 受信タブの右の詳細。選んでいる提案の出どころ（受信名と時刻）・本文の全体・リンク、タスクにしたときのタイトルと期限、
/// 「タスクにする」「捨てる」のボタン。収まらなければ欄ごとスクロールし、収まる間はボタンを下端へ押す。
struct TaskPaletteIntakeDetail: View {
  @Bindable var model: TaskPaletteIntakeModel
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

  private var text: IntakeText {
    IntakeText(l10n: l10n, today: model.today, timeZone: model.timeZone)
  }

  @ViewBuilder private func content(_ proposal: IntakeProposal) -> some View {
    // 受信名は縮め、時刻は残す。
    HStack(spacing: Theme.Space.note + 1) {
      Image(systemName: "tray.and.arrow.down")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.theme.accentBright)
      if let name = model.store.shelf(of: proposal)?.definition.name {
        TruncatingSlot(name) { fontResolver.text($0, base: Theme.Typography.meta) }
        Text("·")
      }
      Text(text.moment(proposal.item.time)).fixedSize()
    }
    .font(Font.theme.meta)
    .foregroundStyle(Color.theme.textMuted)
    quote(proposal)
      .padding(.top, Theme.Space.beat)
    Text(l10n.string(.taskPaletteIntakeAsTask))
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
  }

  /// 本文の全体と「↗ <ホスト名> で開く」（クリックか ⌘↵ でブラウザで開く）。
  private func quote(_ proposal: IntakeProposal) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.note) {
      fontResolver.text(proposal.item.body, base: Theme.Typography.workspaceName)
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textPrimary)
        .lineSpacing(Theme.Space.tick)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        model.openLink()
      } label: {
        Text("↗ " + l10n.format(.taskPaletteIntakeOpenLink, IntakeText.host(proposal.item.link)))
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

  private var buttons: some View {
    HStack(spacing: Theme.Space.step) {
      TaskPaneButton(key: "↵", title: l10n.string(.taskPaletteMakeTask), primary: true) {
        model.accept()
      }
      TaskPaneButton(key: "⌘⌫", title: l10n.string(.taskPaletteIntakeDismiss)) {
        model.dismiss()
      }
    }
  }
}
