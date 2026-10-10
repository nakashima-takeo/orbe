import SwiftUI

/// 選んだ自動追加の詳細（右）。名前・取得・判定の指示・いつ・回の記録。取得と判定は 1 行の要約にせず全文を出す——承認なしで
/// 裏で走るもの（使えるツール・コマンド・作業ディレクトリ）を、いつも確かめられるため。原文も素の文字で描き、欄全体が縦に
/// スクロールする（選択が替わると先頭へ戻る）。
struct BoardIntakeDetail: View {
  let standing: BoardIntakeStanding
  let text: IntakeText
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  private var intake: Intake { standing.intake }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Space.bar) {
        fontResolver.text(intake.definition.name, base: Theme.Typography.boardDetailTitle)
          .font(Font.theme.boardDetailTitle)
          .foregroundStyle(Color.theme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
        field(.intakeFetch) { lines(text.fetch(intake.definition.fetch)) }
        field(.boardIntakeJudge) { lines(text.judge(intake.definition.judge)) }
        field(.boardIntakeWhen) {
          value(
            text.when(intake.definition.when)
              + (intake.paused ? l10n.string(.boardIntakePausedNote) : ""))
        }
        runs
      }
      .padding(.vertical, Theme.Space.bar)
      .padding(.horizontal, Theme.Space.bar + Theme.Space.hair)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .id(standing.id)
    .scrollIndicators(.automatic)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.theme.surfaceInk.opacity(0.025))
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.card)
        .strokeBorder(Color.theme.borderInk.opacity(0.06), lineWidth: Theme.Stroke.hairline))
  }

  private func field<Content: View>(_ label: L10nKey, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: Theme.Space.tick) {
      Text(l10n.string(label))
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textSecondary)
      VStack(alignment: .leading, spacing: 0) { content() }
    }
  }

  private func lines(_ lines: [IntakeText.Line]) -> some View {
    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
      switch line {
      case .plain(let line), .source(let line): value(line)
      }
    }
  }

  private func value(_ value: String) -> some View {
    fontResolver.text(value, base: Theme.Typography.boardValue)
      .font(Font.theme.boardValue)
      .foregroundStyle(Color.theme.textPrimary)
      .lineSpacing(Self.valueLeading)
      .padding(.vertical, Self.valueLeading / 2)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// 回の記録（新しい順・最大 20 件）。失敗は理由の全文を赤で折り返す。
  private var runs: some View {
    VStack(alignment: .leading, spacing: Theme.Space.note) {
      Text(l10n.string(.boardIntakeRuns))
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textSecondary)
      if intake.runs.isEmpty {
        log(l10n.string(.intakeNeverRan), color: Color.theme.textMuted)
      }
      ForEach(Array(intake.runs.enumerated()), id: \.offset) { _, run in
        log(
          text.runLine(run),
          color: run.failure == nil ? Color.theme.textSecondary : Color.theme.danger)
      }
    }
  }

  private func log(_ value: String, color: Color) -> some View {
    fontResolver.text(value, base: Theme.Typography.workspaceName)
      .font(Font.theme.workspaceName)
      .foregroundStyle(color)
      .lineSpacing(Self.logLeading)
      .padding(.vertical, Self.logLeading / 2)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// 行高 1.6 に当たる行間。1 行目の上と最終行の下にも半分ずつ置く（CSS の line-height と同じ組み方）。
  private static let valueLeading = Theme.Typography.boardValue.extraLeading(
    lineHeight: Theme.Typography.lineBody)
  private static let logLeading = Theme.Typography.workspaceName.extraLeading(
    lineHeight: Theme.Typography.lineBody)
}
