import SwiftUI

/// 提案タブの左の棚。先頭に「すべて」、続いて自動化ごとに名前・件数・2 行目（次の判定 / 停止中 / 更新中…と、失敗した部品）。
/// 候補の無い自動化は減光する。下に、自動化を足す・変える口が Home のボードであることを添える（この画面では定義を変えない）。
struct TaskPaletteAutomationShelf: View {
  @Bindable var model: TaskPaletteAutomationModel
  @Environment(\.localization) private var l10n

  var body: some View {
    let list = model.shelfList
    VStack(alignment: .leading, spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: Theme.Space.hair) {
            ForEach(model.shelfRows) { row($0) }
          }
          .padding(.horizontal, Theme.Space.step + Theme.Space.hair)
          .padding(.vertical, Theme.Space.beat)
        }
        .scrollIndicators(.automatic)
        .onChange(of: list.scrollTarget) {
          if let id = list.scrollTarget?.id { proxy.scrollTo(id) }
        }
      }
      Text(l10n.string(.taskPaletteAutomationAskBoard))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Theme.Space.span)
        .padding(.vertical, Theme.Space.beat)
    }
  }

  private func row(_ row: TaskPaletteAutomationShelfRow) -> some View {
    TaskPaletteAutomationShelfRowView(
      row: row, status: row.automation.map { model.status(of: $0, count: row.count) },
      text: AutomationText(l10n: l10n, today: model.today, timeZone: model.timeZone),
      selected: model.shelfList.selectedID == row.id
    )
    .contentShape(Rectangle())
    .onTapGesture { model.tapShelf(row.id) }
    .onHover { if $0 { model.hoverShelf(row.id) } }
    .id(row.id)
  }
}

/// 棚の 1 段。印はどの受信も共通（出どころの種類は知らない）。
private struct TaskPaletteAutomationShelfRowView: View {
  let row: TaskPaletteAutomationShelfRow
  let status: TaskPaletteAutomationShelfStatus?
  let text: AutomationText
  let selected: Bool
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Space.step + 1) {
      Group {
        if row.automation != nil {
          Image(systemName: "tray.and.arrow.down")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.theme.accentBright)
        } else {
          Color.clear
        }
      }
      .frame(width: 12, height: 18)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .top, spacing: Theme.Space.step) {
          fontResolver.text(name, base: Theme.Typography.workspaceName)
            .font(Font.theme.workspaceName)
            .foregroundStyle(dimmed ? Color.theme.textMuted : Color.theme.textPrimary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Text("\(row.count)")
            .font(Font.theme.workspaceName)
            .foregroundStyle(Color.theme.textMuted)
        }
        if let status {
          line(status)
            .font(Font.theme.meta)
            .lineLimit(2)
        }
      }
    }
    .padding(.vertical, Theme.Space.step + 1)
    .padding(.horizontal, Theme.Space.beat)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(selected ? Color.theme.selectionFill : .clear))
  }

  private var name: String {
    row.automation?.name ?? l10n.string(.taskPaletteAutomationAll)
  }

  private var dimmed: Bool { row.automation != nil && row.count == 0 }

  /// 「次の判定 9:00 · 候補なし · 判定: 連絡 · 失敗」。更新中は強調色でそれだけ、失敗した部品は赤（どちらも文字でも言う）。
  private func line(_ status: TaskPaletteAutomationShelfStatus) -> Text {
    let muted = { (value: String) in Text(value).foregroundStyle(Color.theme.textMuted) }
    guard case .standing(let plan, let noCandidates, let failed) = status else {
      return Text(l10n.string(.taskPaletteAutomationRefreshing))
        .foregroundStyle(Color.theme.accentBright)
    }
    var parts: [Text] = []
    switch plan {
    case .paused: parts.append(muted(l10n.string(.automationPaused)))
    case .at(let date):
      parts.append(muted(l10n.format(.taskPaletteAutomationNextJudge, text.stamp(date))))
    case .onArrival: parts.append(muted(l10n.string(.taskPaletteAutomationJudgeOnArrival)))
    case .manual: parts.append(muted(l10n.string(.taskPaletteAutomationJudgeManual)))
    case nil: break
    }
    if noCandidates { parts.append(muted(l10n.string(.taskPaletteAutomationNoProposals))) }
    if let failed = text.failed(failed) {
      parts.append(Text(failed).foregroundStyle(Color.theme.danger))
    }
    guard let first = parts.first else { return Text("") }
    return parts.dropFirst().reduce(first) { $0 + muted(" · ") + $1 }
  }
}
