import SwiftUI

/// 詳細の「実行履歴」。見出しの右に帯（畳んだ後の直近の行。古い行が左）、下に全部品の回を新しい順の 1 行ずつ（時刻・部品の名前・
/// 結果）。結果は 1 行で末尾を省き、全文は選んだ部品のカードの「この部品の回」で読む。
struct BoardAutomationHistory: View {
  let detail: BoardAutomationDetailValue
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      BoardSectionHeader(title: .boardAutomationRuns) {
        HStack(spacing: Theme.Space.hair) {
          ForEach(Array(detail.strip.enumerated()), id: \.offset) { _, tone in
            RoundedRectangle(cornerRadius: 1)
              .fill(BoardRunColors.strip(tone))
              .frame(width: Theme.Space.tick, height: 10)
          }
        }
      }
      if detail.runs.isEmpty {
        Text(l10n.string(.automationNeverRan))
          .font(Font.theme.codeSmall)
          .foregroundStyle(Color.theme.textMuted)
          .frame(height: BoardRunList.line)
      } else {
        BoardRunList(lines: detail.runs, minTime: 40, wraps: false)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 回の行の並び（実行履歴とカードの「この部品の回」）。列は時刻・部品の名前（あれば）・結果。畳んだ行は列をまたぐ 1 行。
/// `wraps` なら失敗の理由・報告・応答の行を全文で折り返す。
struct BoardRunList: View {
  let lines: [BoardRunLine]
  let minTime: CGFloat
  let wraps: Bool
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    let entries = lines.compactMap { line -> BoardRunEntry? in
      if case .run(let entry) = line { return entry }
      return nil
    }
    let time = max(
      minTime,
      entries.map { fontResolver.width($0.at, base: Theme.Typography.codeSmall) }.max()?
        .rounded(.up) ?? 0)
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        switch line {
        case .run(let entry): row(entry, time: time)
        case .fold(let text):
          Text(text)
            .foregroundStyle(Color.theme.textMuted)
            .frame(maxWidth: .infinity, minHeight: Self.line, alignment: .leading)
        }
      }
    }
    .font(Font.theme.codeSmall)
    .lineLimit(1)
    .truncationMode(.tail)
  }

  private func row(_ entry: BoardRunEntry, time: CGFloat) -> some View {
    HStack(alignment: .top, spacing: Self.columnGap) {
      Text(entry.at)
        .foregroundStyle(Color.theme.textSecondary)
        .frame(width: time, height: Self.line, alignment: .leading)
      if let part = entry.part {
        fontResolver.text(part, base: Theme.Typography.codeSmall)
          .foregroundStyle(Color.theme.textMuted)
          .frame(width: Self.partWidth, height: Self.line, alignment: .leading)
      }
      result(entry)
    }
  }

  @ViewBuilder private func result(_ entry: BoardRunEntry) -> some View {
    let text = fontResolver.text(entry.result, base: Theme.Typography.codeSmall)
      .foregroundStyle(BoardRunColors.result(entry.shade))
    if wraps && entry.wraps {
      text
        .lineLimit(nil)
        .lineSpacing(Self.wrapLeading)
        .padding(.vertical, Self.wrapInset)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      text.frame(maxWidth: .infinity, minHeight: Self.line, alignment: .leading)
    }
  }

  static let line: CGFloat = 24
  private static let columnGap: CGFloat = 10
  private static let partWidth: CGFloat = 110
  /// 折り返した全文は行の高さ 18（見本）で、1 行の行と同じ上下の余白で並ぶ。
  private static let wrapLeading = Theme.Typography.codeSmall.extraLeading(
    lineHeight: 18 / Theme.Typography.codeSmall.pointSize)
  private static let wrapInset: CGFloat = 3 + wrapLeading / 2
}
