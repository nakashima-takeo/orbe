import SwiftUI

/// 依頼の欄を選んでいる間の右の欄。どう頼めば一覧に加わるかの一文と、入力例。
struct BoardAutomationGuide: View {
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(l10n.string(.boardGuideLead))
        .font(Font.theme.code)
        .foregroundStyle(Color.theme.textPrimary)
        .lineSpacing(Self.leadLeading)
        .padding(.vertical, Self.leadLeading / 2)
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: Theme.Space.note) {
        Text(l10n.string(.boardGuideExamples))
          .font(Font.theme.codeSmall)
          .foregroundStyle(Color.theme.textMuted)
        ForEach(BoardAutomationExamples.all, id: \.self) { example in
          HStack(alignment: .firstTextBaseline, spacing: Self.promptGap) {
            Text(verbatim: "❯").foregroundStyle(Color.theme.kbKeyMutedText)
            Text(l10n.string(example))
              .foregroundStyle(Color.theme.textPrimary)
              .lineSpacing(Self.exampleLeading)
              .padding(.vertical, Self.exampleLeading / 2)
              .fixedSize(horizontal: false, vertical: true)
          }
          .font(Font.theme.workspaceName)
        }
      }
    }
    .padding(.vertical, 28)
    .padding(.horizontal, 32)
    .frame(maxWidth: Self.maxWidth, alignment: .leading)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private static let promptGap: CGFloat = 10
  private static let maxWidth: CGFloat = 760
  private static let leadLeading = Theme.Typography.code.extraLeading(lineHeight: 1.7)
  private static let exampleLeading = Theme.Typography.workspaceName.extraLeading(
    lineHeight: Theme.Typography.lineBody)
}
