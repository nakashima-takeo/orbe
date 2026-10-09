import SwiftUI

/// 受信タブの左の棚。先頭に「すべて」、続いて受信ごとに名前・件数・2 行目（次の時刻 / 止めている / 受信中…）。提案の無い受信は
/// 減光する。下に、受信を足す・変える口が秘書であることを添える（この画面では定義を変えない）。
struct TaskPaletteIntakeShelf: View {
  @Bindable var model: TaskPaletteIntakeModel
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
      Text(l10n.string(.taskPaletteIntakeAskSecretary))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Theme.Space.span)
        .padding(.vertical, Theme.Space.beat)
    }
  }

  private func row(_ row: TaskPaletteIntakeShelfRow) -> some View {
    TaskPaletteIntakeShelfRowView(
      row: row, running: row.intake.map(model.isRunning) ?? false,
      next: row.intake.flatMap(model.nextRunAt),
      text: IntakeText(l10n: l10n, today: model.today, timeZone: model.timeZone),
      selected: model.shelfList.selectedID == row.id
    )
    .contentShape(Rectangle())
    .onTapGesture { model.tapShelf(row.id) }
    .onHover { if $0 { model.hoverShelf(row.id) } }
    .id(row.id)
  }
}

/// 棚の 1 段。印はどの受信も共通（出どころの種類は知らない）。
private struct TaskPaletteIntakeShelfRowView: View {
  let row: TaskPaletteIntakeShelfRow
  let running: Bool
  let next: Date?
  let text: IntakeText
  let selected: Bool
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Space.step + 1) {
      Group {
        if row.intake != nil {
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
        if let intake = row.intake {
          status(intake)
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
    row.intake?.definition.name ?? l10n.string(.taskPaletteScopeAll)
  }

  private var dimmed: Bool { row.intake != nil && row.count == 0 }

  /// 「次 17:00 · 提案なし · 前回は失敗」。受信中は強調色、前回の失敗は赤（どちらも文字でも言う）。
  private func status(_ intake: Intake) -> Text {
    let muted = { (value: String) in Text(value).foregroundStyle(Color.theme.textMuted) }
    var parts: [Text] = []
    if running {
      parts.append(
        Text(l10n.string(.taskPaletteIntakeRunning)).foregroundStyle(Color.theme.accentBright))
    } else if intake.paused {
      parts.append(muted(l10n.string(.taskPaletteIntakePaused)))
    } else if let next {
      parts.append(muted(l10n.format(.taskPaletteIntakeNext, text.stamp(next))))
    }
    if row.count == 0 { parts.append(muted(l10n.string(.taskPaletteIntakeNoProposals))) }
    if intake.runs.first?.failure != nil {
      parts.append(
        Text(l10n.string(.taskPaletteIntakeLastFailed)).foregroundStyle(Color.theme.danger))
    }
    guard let first = parts.first else { return Text("") }
    return parts.dropFirst().reduce(first) { $0 + muted(" · ") + $1 }
  }
}
