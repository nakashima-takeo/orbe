import SwiftUI

/// 詳細の「流れ」。部品を入力の深さ順に 1 行ずつ縦に並べる。行は役割・名前・予定の札・入力の部品名・溜まりの件数・前回の件数。
/// 下に累計と通知の注記。
struct BoardAutomationFlowView: View {
  let summary: BoardAutomationSummary
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      BoardSectionHeader(title: .boardAutomationFlow) {
        Text(l10n.string(.boardAutomationCounts)).foregroundStyle(Color.theme.textMuted)
      }
      .padding(.bottom, Self.ruleBelow)
      ForEach(summary.parts, id: \.key) { BoardPartRow(part: $0) }
      ForEach(Array(summary.notes.enumerated()), id: \.offset) { _, note in
        fontResolver.text(note, base: Theme.Typography.codeSmall)
          .font(Font.theme.codeSmall)
          .foregroundStyle(Color.theme.textMuted)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, Theme.Space.note)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private static let ruleBelow: CGFloat = 14
}

/// 流れの部品 1 行。左に役割、中に名前と予定の札と入力、右に溜まりと前回の件数。
struct BoardPartRow: View {
  let part: BoardPartLine
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
      Text(part.role)
        .font(Font.theme.codeSmall)
        .foregroundStyle(Color.theme.textMuted)
        .frame(width: Self.roleWidth, alignment: .leading)
      VStack(alignment: .leading, spacing: Theme.Space.tick) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.step) {
          fontResolver.text(part.name, base: Theme.Typography.code)
            .font(Font.theme.code)
            .foregroundStyle(Color.theme.textPrimary)
          BoardFlowChip(text: part.schedule).fixedSize()
        }
        if let inputs = part.inputs {
          fontResolver.text("← " + inputs, base: Theme.Typography.codeSmall)
            .font(Font.theme.codeSmall)
            .foregroundStyle(Color.theme.textMuted)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: Self.gap) {
        if let inbox = part.inbox {
          Text(l10n.format(.boardPartInbox, inbox))
            .foregroundStyle(inbox > 0 ? Color.theme.textPrimary : Color.theme.textMuted)
        }
        Text(part.count.map { "\($0)" } ?? "–")
          .foregroundStyle(Color.theme.textSecondary)
          .frame(width: Self.countWidth, alignment: .trailing)
      }
      .font(Font.theme.codeSmall)
      .fixedSize()
    }
    .lineLimit(1)
    .padding(.vertical, Self.rowInset)
  }

  private static let gap: CGFloat = 10
  private static let roleWidth: CGFloat = 44
  /// 3 桁の数が入る幅。
  private static let countWidth: CGFloat = 26
  private static let rowInset: CGFloat = 6
}

/// 流れの予定の札。
struct BoardFlowChip: View {
  let text: String

  var body: some View {
    Text(text)
      .font(Font.theme.meta)
      .foregroundStyle(Color.theme.textSecondary)
      .padding(.horizontal, 7)
      .frame(minHeight: 18)
      .background(Color.theme.plainPillFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
  }
}
