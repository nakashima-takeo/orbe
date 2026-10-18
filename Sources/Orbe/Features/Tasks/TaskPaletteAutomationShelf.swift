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
      row: row, status: row.automation.map { model.status(of: $0) },
      text: AutomationText(l10n: l10n, today: model.today, timeZone: model.timeZone),
      selected: model.shelfList.selectedID == row.id, focused: model.place == .shelf
    )
    .contentShape(Rectangle())
    .onTapGesture { model.tapShelf(row.id) }
    .onHover { if $0 { model.hoverShelf(row.id) } }
    .id(row.id)
  }
}

/// 棚の 1 段。上に印・名前・件数、下に前回の判定（成否の印と時刻）と今の状態（更新中・停止中）。印はどの受信も共通（出どころの
/// 種類は知らない）。棚に焦点が無い間は、選択の地を薄くする（選んでいるが、キーが届く場所ではない）。
private struct TaskPaletteAutomationShelfRowView: View {
  let row: TaskPaletteAutomationShelfRow
  let status: TaskPaletteAutomationShelfStatus?
  let text: AutomationText
  let selected: Bool
  let focused: Bool
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Group {
        if row.automation != nil {
          MarkGlyph(kind: .tray, color: Color.theme.accentBright)
        } else {
          Color.clear
        }
      }
      .frame(width: 12, height: 18)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .top, spacing: Theme.Space.step) {
          fontResolver.text(name, base: Theme.Typography.workspaceName)
            .font(Font.theme.workspaceName)
            .foregroundStyle(Color.theme.textPrimary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Text(verbatim: "\(row.count)")
            .font(Font.theme.workspaceName)
            .foregroundStyle(Color.theme.textMuted)
        }
        .frame(minHeight: 18)
        if let status { line(status) }
      }
    }
    .padding(.vertical, 9)
    .padding(.horizontal, Theme.Space.beat)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .fill(
          selected
            ? (focused ? Color.theme.selectionFill : Color.theme.surfaceInk.opacity(0.06))
            : .clear))
  }

  private var name: String {
    row.automation?.name ?? l10n.string(.taskPaletteAutomationAll)
  }

  /// 成否の印と「前回の判定 13:00」、右に「更新中」「停止中」。まだ判定していなければ印なしの一言。並びきらない狭い棚では、
  /// 今の状態を次の行へ送る（前回の時刻を省かない）。
  private func line(_ status: TaskPaletteAutomationShelfStatus) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        last(status)
        Spacer(minLength: Theme.Space.tick)
        state(status)
      }
      VStack(alignment: .leading, spacing: 3) {
        last(status)
        state(status)
      }
    }
    .font(Font.theme.meta)
    .foregroundStyle(Color.theme.textMuted)
    .lineLimit(1)
    .frame(minHeight: 15)
  }

  private func last(_ status: TaskPaletteAutomationShelfStatus) -> some View {
    HStack(spacing: 6) {
      if let last = status.last {
        MarkGlyph(
          kind: last.failed ? .failure : .success,
          color: last.failed ? Color.theme.danger : Color.theme.accentBright)
        Text(l10n.format(.taskPaletteAutomationLastJudge, text.stamp(last.at)))
      } else {
        Text(l10n.string(.taskPaletteAutomationNeverJudged))
      }
    }
    .fixedSize()
  }

  @ViewBuilder private func state(_ status: TaskPaletteAutomationShelfStatus) -> some View {
    switch status.state {
    case .refreshing:
      HStack(spacing: 5) {
        StatusGlyphView(kind: .working, size: 10)
        Text(l10n.string(.taskPaletteAutomationRefreshing))
      }
      .foregroundStyle(Color.theme.accentBright)
      .fixedSize()
    case .paused:
      HStack(spacing: 5) {
        MarkGlyph(kind: .paused, color: Color.theme.textMuted)
        Text(l10n.string(.automationPaused))
      }
      .fixedSize()
    case nil:
      EmptyView()
    }
  }
}
