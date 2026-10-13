import SwiftUI

/// 自動追加の中身（真ん中と右をまたぐ 1 枚）。名前と状態、取得（やり方といつ）・処理・前回の回・重なり、定義を書き換える口が
/// ボードであること、操作（`AutomationHand`）。値は走らせ役とストアから毎回読むので、裏の回が確定すると
/// そのまま映る。
struct TaskPaletteAutomationContents: View {
  @Bindable var model: TaskPaletteAutomationModel
  let automation: Automation
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          heading
          section(.automationFetch) { fetch }
          section(.automationSteps) { steps }
          section(.taskPaletteAutomationLast) { last }
          let overlaps = model.store.overlaps(of: automation.id)
          if !overlaps.isEmpty {
            section(.taskPaletteAutomationOverlaps) {
              ForEach(overlaps, id: \.automation.id) { overlap in
                fontResolver.text(
                  l10n.format(
                    .taskPaletteAutomationOverlapCount, overlap.automation.definition.name,
                    overlap.count),
                  base: Theme.Typography.workspaceName
                )
                .font(Font.theme.workspaceName)
                .foregroundStyle(Color.theme.textSecondary)
              }
            }
          }
          Text(l10n.string(.taskPaletteAutomationRewriteNote))
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

  private var text: AutomationText {
    AutomationText(l10n: l10n, today: model.today, timeZone: model.timeZone)
  }

  private var heading: some View {
    VStack(alignment: .leading, spacing: Theme.Space.note) {
      fontResolver.text(automation.definition.name, base: Theme.Typography.title)
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Group {
        if model.isRunning(automation) {
          Text(l10n.string(.automationRunning)).foregroundStyle(Color.theme.accentBright)
        } else if automation.paused {
          Text(l10n.string(.automationPaused)).foregroundStyle(Color.theme.textMuted)
        } else if let next = model.nextRunAt(automation) {
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
    if let source = automation.definition.source { lines(text.source(source)) }
    line(text.when(automation.definition.trigger))
  }

  private var steps: some View {
    lines(text.steps(automation.definition))
  }

  private func lines(_ lines: [AutomationText.Line]) -> some View {
    ForEach(Array(lines.enumerated()), id: \.offset) { _, value in
      switch value {
      case .plain(let value): line(value)
      case .verbatim(let value): quote(value)
      }
    }
  }

  private var last: some View {
    let run = automation.runs.first
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
          Text(AutomationHand.Operation.delete.key)
          Text(l10n.string(AutomationHand.Operation.delete.title(paused: automation.paused)))
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

  private func button(_ operation: AutomationHand.Operation, primary: Bool = false) -> some View {
    TaskPaneButton(
      key: operation.key, title: l10n.string(operation.title(paused: automation.paused)),
      primary: primary
    ) { model.perform(operation) }
  }
}
