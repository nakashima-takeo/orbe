import SwiftUI

/// 選んだ部品のカード。頭（点・役割・名前）・札（モデルかコマンド・ツール・予定）・項目・指示文かコマンド・決まりを外した印・
/// この部品の回・ボタン「↵ ここまで今すぐ流す」。ボタンは地図の ↵ と同じ手の操作を通る（名前もそこから読む）。
struct BoardAutomationPartCard: View {
  let model: BoardAutomationModel
  let card: BoardAutomationPartValue
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    VStack(alignment: .leading, spacing: Self.gap) {
      HStack(spacing: Theme.Space.step) {
        BoardNodeView(look: card.look).frame(width: 11, height: 11)
        Text(card.role)
          .font(Font.theme.codeSmall)
          .foregroundStyle(Color.theme.textMuted)
        fontResolver.text(card.name, base: Theme.Typography.title)
          .font(Font(Theme.Typography.title.monospacedWeight(.semibold)))
          .foregroundStyle(Color.theme.textPrimary)
          .lineLimit(1)
      }
      chips
      facts
      fontResolver.text(card.body, base: Theme.Typography.codeCompact)
        .font(Font.theme.codeCompact)
        .foregroundStyle(Color.theme.textPrimary)
        .lineSpacing(Self.bodyLeading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.theme.inputWash, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.theme.inputBorder, lineWidth: Theme.Stroke.hairline))
      if let breach = card.breach {
        VStack(alignment: .leading, spacing: Theme.Space.hair) {
          Text(breach.summary).foregroundStyle(Color.theme.danger)
          ForEach(Array(breach.reasons.enumerated()), id: \.offset) { _, reason in
            fontResolver.text(reason, base: Theme.Typography.codeSmall)
              .foregroundStyle(Color.theme.textSecondary)
          }
        }
        .font(Font.theme.codeSmall)
        .fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 0) {
        BoardSectionHeader(title: .boardPartRuns, below: Theme.Space.tick) { EmptyView() }
        if card.runs.isEmpty {
          Text(l10n.string(.automationNeverRan))
            .font(Font.theme.codeSmall)
            .foregroundStyle(Color.theme.textMuted)
            .frame(height: BoardRunList.line)
        } else {
          BoardRunList(lines: card.runs, minTime: 64, wraps: true)
        }
      }
      button
    }
    .padding(.vertical, 16)
    .padding(.horizontal, 18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.theme.surfaceInk.opacity(0.02), in: RoundedRectangle(cornerRadius: Theme.Radius.md)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.md)
        .strokeBorder(Color.theme.surface1, lineWidth: Theme.Stroke.hairline))
  }

  private var chips: some View {
    BoardChipFlow(spacing: 6) {
      if let model = card.model {
        BoardChip(text: model, foreground: Color.theme.accentBright, fill: Color.theme.tintAccent)
      } else {
        BoardChip(text: l10n.string(.boardOutputCommand))
      }
      ForEach(card.tools, id: \.self) { BoardChip(text: $0) }
      BoardScheduleChip(text: card.schedule, arrival: card.arrival)
    }
  }

  private var facts: some View {
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: Theme.Space.tick) {
      ForEach(Array(card.facts.enumerated()), id: \.offset) { _, fact in
        GridRow(alignment: .firstTextBaseline) {
          Text(l10n.string(fact.label))
            .foregroundStyle(Color.theme.textMuted)
            .frame(width: 56, alignment: .leading)
          fontResolver.text(fact.value, base: Theme.Typography.codeSmall)
            .foregroundStyle(fact.emphasized ? Color.theme.accentBright : Color.theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        }
      }
    }
    .font(Font.theme.codeSmall)
  }

  private var button: some View {
    let operation = BoardAutomationHand.Operation.flow(.part)
    return Button {
      model.flow(to: card.key)
    } label: {
      HStack(spacing: 6) {
        Text(operation.key).foregroundStyle(Color.theme.accentBright)
        Text(l10n.string(operation.title(paused: false))).foregroundStyle(Color.theme.textPrimary)
      }
      .font(Font.theme.workspaceName)
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(Color.theme.tintAccent, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
  }

  private static let gap: CGFloat = 12
  /// 指示文の行の高さ 1.6（見本）に当たる行間。
  private static let bodyLeading = Theme.Typography.codeCompact.extraLeading(lineHeight: 1.6)
}

/// 札を左から並べ、幅に収まらなければ次の行へ送る。
struct BoardChipFlow: Layout {
  let spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(subviews, width: proposal.width ?? .infinity)
    return CGSize(
      width: rows.map(\.width).max() ?? 0,
      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in arrange(subviews, width: bounds.width) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
    var rows: [Row] = []
    var row = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      if !row.indices.isEmpty && next > width {
        rows.append(row)
        row = Row()
      }
      row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      row.height = max(row.height, size.height)
      row.indices.append(index)
    }
    if !row.indices.isEmpty { rows.append(row) }
    return rows
  }
}
