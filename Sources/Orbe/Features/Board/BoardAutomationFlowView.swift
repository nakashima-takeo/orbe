import SwiftUI

/// 詳細の「流れ」。段を縦の線でつなぎ、各段に役割・名前・手段の札・原文の全文、右に前回の件数の棒を出す。件数の列は取得元を
/// 持つ並びだけに出す。
struct BoardAutomationFlowView: View {
  let summary: BoardAutomationSummary
  @Environment(\.localization) private var l10n

  var body: some View {
    let counted = summary.counted
    let most = summary.nodes.compactMap(\.count).max() ?? 0
    VStack(alignment: .leading, spacing: 0) {
      BoardSectionHeader(title: .boardAutomationFlow) {
        if counted {
          Text(l10n.string(.boardAutomationCounts)).foregroundStyle(Color.theme.textMuted)
        }
      }
      .padding(.bottom, Self.ruleBelow)
      ForEach(Array(summary.nodes.enumerated()), id: \.offset) { index, node in
        BoardFlowNodeRow(
          node: node, last: index == summary.nodes.count - 1, counted: counted, most: most)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private static let ruleBelow: CGFloat = 14
}

/// 流れの段 1 つ。左に点と次の段への線、中に本文、右に件数。
struct BoardFlowNodeRow: View {
  let node: BoardFlowNode
  let last: Bool
  let counted: Bool
  /// 棒の長さの基準（その回の件数の最大）。
  let most: Int
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(alignment: .top, spacing: Self.gap) {
      rail
      content
      if counted { count }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private var rail: some View {
    VStack(spacing: Theme.Space.tick) {
      dot
      Rectangle()
        .fill(last ? Color.clear : Color.theme.borderInk.opacity(0.14))
        .frame(width: Theme.Stroke.hairline)
        .frame(maxHeight: .infinity)
    }
    .padding(.top, Theme.Space.note)
    .frame(width: Self.railWidth)
  }

  @ViewBuilder private var dot: some View {
    switch node.role {
    case .orbe:
      Circle()
        .strokeBorder(
          Color.theme.kbKeyMutedText,
          style: StrokeStyle(lineWidth: Theme.Stroke.hairline, dash: [2, 1.5])
        )
        .frame(width: Self.orbeDot, height: Self.orbeDot)
    case .output:
      Circle().fill(Color.theme.accentPrimary).frame(width: Self.dot, height: Self.dot)
    case .trigger, .source, .step:
      Circle()
        .strokeBorder(Color.theme.accentPrimary, lineWidth: Theme.Stroke.hairline)
        .frame(width: Self.dot, height: Self.dot)
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: Theme.Space.note) {
      HStack(alignment: .firstTextBaseline, spacing: Self.titleGap) {
        Text(role)
          .font(Font.theme.codeSmall)
          .foregroundStyle(Color.theme.textMuted)
          .frame(width: Self.roleWidth, alignment: .leading)
        if node.role == .orbe {
          Text(node.title)
            .font(Font.theme.codeSmall)
            .foregroundStyle(Color.theme.textMuted)
        } else if !node.title.isEmpty {
          fontResolver.text(node.title, base: Theme.Typography.code)
            .font(Font.theme.code)
            .foregroundStyle(Color.theme.textPrimary)
        }
        if let means = node.means { BoardFlowChip(means: means).fixedSize() }
      }
      .frame(minHeight: Self.titleLine)
      Group {
        if let source = node.source {
          fontResolver.text(source, base: Theme.Typography.codeCompact)
            .font(Font.theme.codeCompact)
            .foregroundStyle(Color.theme.textPrimary)
            .lineSpacing(Self.sourceLeading)
            .padding(.vertical, Self.sourceLeading / 2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Theme.Space.note)
            .padding(.horizontal, Self.boxInset)
            .frame(maxWidth: Self.boxMaxWidth, alignment: .leading)
            .background(Color.theme.inputWash, in: RoundedRectangle(cornerRadius: Self.boxRadius))
            .overlay(
              RoundedRectangle(cornerRadius: Self.boxRadius)
                .strokeBorder(Color.theme.inputBorder, lineWidth: Theme.Stroke.hairline))
        }
        if !node.tools.isEmpty {
          BoardChipFlow(spacing: Theme.Space.tick) {
            ForEach(node.tools, id: \.self) { BoardFlowChip(means: .command($0)) }
          }
        }
        if let note = node.note {
          Text(note)
            .font(Font.theme.codeSmall)
            .foregroundStyle(Color.theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.leading, Self.roleWidth + Self.titleGap)
    }
    .padding(.bottom, below)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var count: some View {
    HStack(spacing: Self.titleGap) {
      if let count = node.count {
        Capsule()
          .fill(
            node.role == .orbe
              ? Color.theme.borderInk.opacity(0.18) : Color.theme.accentPrimary.opacity(0.55)
          )
          .frame(width: most == 0 ? 0 : Self.barMax * CGFloat(count) / CGFloat(most), height: 6)
        Text(verbatim: "\(count)")
          .font(Font.theme.workspaceName)
          .foregroundStyle(node.role == .orbe ? Color.theme.textMuted : Color.theme.textPrimary)
          .frame(width: Self.countWidth, alignment: .trailing)
      }
    }
    .frame(width: Self.countColumn, height: Self.titleLine, alignment: .trailing)
  }

  private var role: String {
    switch node.role {
    case .trigger: l10n.string(.boardRoleTrigger)
    case .source: l10n.string(.boardRoleSource)
    case .orbe: l10n.string(.boardRoleOrbe)
    case .step(let index): l10n.format(.boardRoleStep, index)
    case .output: l10n.string(.boardRoleOutput)
    }
  }

  /// 段の下の間。最後の段は線を描かないので間も持たない。
  private var below: CGFloat {
    if last { return 0 }
    switch node.role {
    case .trigger: return 20
    case .orbe: return 16
    case .source, .step, .output: return 18
    }
  }

  private static let gap: CGFloat = 14
  private static let railWidth: CGFloat = 14
  private static let dot: CGFloat = 9
  private static let orbeDot: CGFloat = 7
  private static let titleGap: CGFloat = 10
  private static let roleWidth: CGFloat = 44
  private static let titleLine: CGFloat = 20
  private static let boxInset: CGFloat = 10
  private static let boxRadius: CGFloat = 6
  private static let boxMaxWidth: CGFloat = 640
  private static let countColumn: CGFloat = 132
  private static let countWidth: CGFloat = 20
  private static let barMax: CGFloat = 96
  /// 行高 1.6 に当たる行間。1 行目の上と最終行の下にも半分ずつ置く（CSS の line-height と同じ組み方）。
  private static let sourceLeading = Theme.Typography.codeCompact.extraLeading(
    lineHeight: Theme.Typography.lineBody)
}

/// 手段の札。モデルは強調の地、コマンド（と使えるツール）は無彩の地。名前は切らない（使えるツールは裏で承認なしに使われる）。
struct BoardFlowChip: View {
  let means: BoardFlowMeans

  var body: some View {
    let (label, model): (String, Bool) =
      switch means {
      case .command(let label): (label, false)
      case .model(let name): (name, true)
      }
    Text(label)
      .font(Font.theme.meta)
      .foregroundStyle(model ? Color.theme.accentBright : Color.theme.textSecondary)
      .padding(.horizontal, 7)
      .frame(minHeight: 18)
      .background(
        model ? Color.theme.accentPrimary.opacity(0.16) : Color.theme.plainPillFill,
        in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
  }
}

/// 札を左から並べ、幅に収まらなければ次の行へ折り返す。欄より長い札は札の中で折り返す。
struct BoardChipFlow: Layout {
  let spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(subviews, width: proposal.width ?? .infinity)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in arrange(subviews, width: bounds.width) {
      var x = bounds.minX
      for index in row.indices {
        let size = size(subviews[index], width: bounds.width)
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

  /// 札 1 つの大きさ。欄より長い札は欄の幅に収める。
  private func size(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
    let ideal = subview.sizeThatFits(.unspecified)
    guard ideal.width > width else { return ideal }
    return subview.sizeThatFits(ProposedViewSize(width: width, height: ideal.height))
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
    var rows: [Row] = []
    var row = Row()
    for index in subviews.indices {
      let size = size(subviews[index], width: width)
      let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
      if !row.indices.isEmpty, next > width {
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
