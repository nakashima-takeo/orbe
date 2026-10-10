import SwiftUI

/// 受信の中身（真ん中と右をまたぐ 1 枚）。名前と状態、取得（やり方といつ）・判定・前回の回・重なり、定義を書き換える口が
/// 秘書であること、操作（今すぐ受信・止める ⇄ 再開・削除）。値は走らせ役とストアから毎回読むので、裏の回が確定すると
/// そのまま映る。
struct TaskPaletteIntakeContents: View {
  @Bindable var model: TaskPaletteIntakeModel
  let intake: Intake
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          heading
          section(.taskPaletteIntakeFetch) { fetch }
          section(.taskPaletteIntakeJudge) { judge }
          section(.taskPaletteIntakeLast) { last }
          let overlaps = model.store.overlaps(of: intake.id)
          if !overlaps.isEmpty {
            section(.taskPaletteIntakeOverlaps) {
              ForEach(overlaps, id: \.intake.id) { overlap in
                fontResolver.text(
                  l10n.format(
                    .taskPaletteIntakeOverlapCount, overlap.intake.definition.name, overlap.count),
                  base: Theme.Typography.workspaceName
                )
                .font(Font.theme.workspaceName)
                .foregroundStyle(Color.theme.textSecondary)
              }
            }
          }
          Text(l10n.string(.taskPaletteIntakeRewriteNote))
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.textMuted)
            .padding(.top, Theme.Space.span)
          Spacer(minLength: Theme.Space.span)
          buttons
        }
        .padding(.horizontal, Theme.Space.phrase)
        .padding(.vertical, Theme.Space.span)
        .frame(width: geometry.size.width, alignment: .leading)
        .frame(minHeight: geometry.size.height, alignment: .top)
      }
      .scrollIndicators(.automatic)
    }
  }

  private var text: IntakeText {
    IntakeText(l10n: l10n, today: model.today, timeZone: model.timeZone)
  }

  private var heading: some View {
    VStack(alignment: .leading, spacing: Theme.Space.note) {
      fontResolver.text(intake.definition.name, base: Theme.Typography.title)
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Group {
        if model.isRunning(intake) {
          Text(l10n.string(.taskPaletteIntakeRunning)).foregroundStyle(Color.theme.accentBright)
        } else if intake.paused {
          Text(l10n.string(.taskPaletteIntakePaused)).foregroundStyle(Color.theme.textMuted)
        } else if let next = model.nextRunAt(intake) {
          Text(l10n.format(.taskPaletteIntakeNext, text.stamp(next)))
            .foregroundStyle(Color.theme.textMuted)
        }
      }
      .font(Font.theme.meta)
    }
  }

  private func section<Content: View>(_ label: L10nKey, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: Theme.Space.note) {
      Text(l10n.string(label))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
      content()
    }
    .padding(.top, Theme.Space.span)
  }

  @ViewBuilder private var fetch: some View {
    switch intake.definition.fetch.method {
    case .agent(let agent):
      line(
        [l10n.string(.taskPaletteIntakeAgentFetch), agent.cli, agent.model].joined(
          separator: " · "))
      line(l10n.string(.taskPaletteIntakeTools) + "  " + agent.tools.joined(separator: ", "))
      quote(agent.request)
    case .command(let command):
      line(l10n.string(.taskPaletteIntakeCommandFetch))
      quote(command.script)
      if let directory = command.directory {
        line(l10n.string(.taskPaletteIntakeDirectory) + "  " + directory)
      }
    }
    line(text.coverage(intake.definition.fetch.coverage))
    line(text.when(intake.definition.when))
  }

  @ViewBuilder private var judge: some View {
    line([intake.definition.judge.cli, intake.definition.judge.model].joined(separator: " · "))
    quote(intake.definition.judge.instruction)
  }

  private var last: some View {
    let run = intake.runs.first
    return fontResolver.text(text.runDetail(run), base: Theme.Typography.workspaceName)
      .font(Font.theme.workspaceName)
      .foregroundStyle(run?.failure == nil ? Color.theme.textSecondary : Color.theme.danger)
      .lineLimit(4)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func line(_ value: String) -> some View {
    fontResolver.text(value, base: Theme.Typography.workspaceName)
      .font(Font.theme.workspaceName)
      .foregroundStyle(Color.theme.textSecondary)
      .lineLimit(2)
  }

  private func quote(_ value: String) -> some View {
    fontResolver.text(value, base: Theme.Typography.workspaceName)
      .font(Font.theme.workspaceName)
      .foregroundStyle(Color.theme.textPrimary)
      .lineLimit(6)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, Theme.Space.step)
      .padding(.horizontal, Theme.Space.beat)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.md)
          .fill(Color.theme.surfaceInk.opacity(0.04)))
  }

  private var buttons: some View {
    HStack(spacing: Theme.Space.step) {
      TaskPaneButton(key: "↵", title: l10n.string(.taskPaletteIntakeRunNow), primary: true) {
        model.runNow()
      }
      TaskPaneButton(
        key: "space",
        title: l10n.string(intake.paused ? .taskPaletteIntakeResume : .taskPaletteIntakePause)
      ) { model.togglePause() }
      Button {
        model.deleteIntake()
      } label: {
        HStack(spacing: Theme.Space.step) {
          Text("⌘⌫")
          Text(l10n.string(.taskPaletteDelete))
        }
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.danger)
        .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
        .frame(height: 26)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable(false)
    }
  }
}
