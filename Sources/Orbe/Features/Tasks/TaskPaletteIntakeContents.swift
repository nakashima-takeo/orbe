import SwiftUI

/// 受信の中身（真ん中と右をまたぐ 1 枚）。名前と状態、取得（やり方といつ）・判定・前回の回・重なり、定義を書き換える口が
/// 秘書であること、操作（`IntakeHand`）。値は走らせ役とストアから毎回読むので、裏の回が確定すると
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
          section(.intakeFetch) { fetch }
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
          Text(l10n.string(.intakeRunning)).foregroundStyle(Color.theme.accentBright)
        } else if intake.paused {
          Text(l10n.string(.intakePaused)).foregroundStyle(Color.theme.textMuted)
        } else if let next = model.nextRunAt(intake) {
          Text(text.next(next))
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
    lines(text.fetch(intake.definition.fetch))
    line(text.when(intake.definition.when))
  }

  private var judge: some View {
    lines(text.judge(intake.definition.judge))
  }

  private func lines(_ lines: [IntakeText.Line]) -> some View {
    ForEach(Array(lines.enumerated()), id: \.offset) { _, value in
      switch value {
      case .plain(let value): line(value)
      case .source(let value): quote(value)
      }
    }
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
      .fixedSize(horizontal: false, vertical: true)
  }

  /// 原文は箱で囲む。
  private func quote(_ value: String) -> some View {
    fontResolver.text(value, base: Theme.Typography.workspaceName)
      .font(Font.theme.workspaceName)
      .foregroundStyle(Color.theme.textPrimary)
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
      button(.runNow, primary: true)
      button(.togglePause)
      Button {
        model.perform(.delete)
      } label: {
        HStack(spacing: Theme.Space.step) {
          Text(IntakeHand.Operation.delete.key)
          Text(l10n.string(IntakeHand.Operation.delete.title(paused: intake.paused)))
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

  private func button(_ operation: IntakeHand.Operation, primary: Bool = false) -> some View {
    TaskPaneButton(
      key: operation.key, title: l10n.string(operation.title(paused: intake.paused)),
      primary: primary
    ) { model.perform(operation) }
  }
}
