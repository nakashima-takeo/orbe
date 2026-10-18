import SwiftUI

/// 選んだ部品のカード。頭（成否の印・役割・名前）・項目・指示文かコマンド・出力の形式エラーの枠・前回の報告か応答・この部品の
/// 実行履歴・ボタン（「⌘↵ ここまで今すぐ実行」「修正を依頼」）。実行のボタンは地図の ⌘↵ と同じ手の操作を通る（キーと名前も
/// そこから読む）。
struct BoardAutomationPartCard: View {
  let model: BoardAutomationModel
  let card: BoardAutomationPartValue
  @Environment(\.localization) private var l10n
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    VStack(alignment: .leading, spacing: Self.gap) {
      head
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
      if let breach = card.breach { self.breach(breach) }
      if let last = card.lastText { lastText(last) }
      history
      buttons
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

  private var head: some View {
    HStack(spacing: Theme.Space.step) {
      if card.look == .running {
        StatusGlyphView(kind: .working, size: 10)
      } else if let mark = card.mark {
        BoardRunMarkGlyph(mark: mark)
      }
      Text(card.role)
        .font(Font.theme.codeSmall)
        .foregroundStyle(Color.theme.textMuted)
      fontResolver.text(card.name, base: Theme.Typography.title)
        .font(Font(Theme.Typography.title.monospacedWeight(.semibold)))
        .foregroundStyle(Color.theme.textPrimary)
        .lineLimit(1)
    }
  }

  private var facts: some View {
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: Theme.Space.tick) {
      ForEach(Array(card.facts.enumerated()), id: \.offset) { _, fact in
        GridRow(alignment: .firstTextBaseline) {
          Text(l10n.string(fact.label))
            .foregroundStyle(Color.theme.textMuted)
            .frame(width: 64, alignment: .leading)
          fact.value.reduce(fact.flow?.lead ?? Text(verbatim: "")) { line, segment in
            line
              + fontResolver.text(segment.text, base: Theme.Typography.codeSmall)
              .foregroundStyle(Self.color(segment.look))
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        }
      }
    }
    .font(Font.theme.codeSmall)
  }

  private static func color(_ look: BoardSegmentLook) -> Color {
    switch look {
    case .plain: Color.theme.textPrimary
    case .muted: Color.theme.textMuted
    case .emphasized: Color.theme.accentBright
    }
  }

  private func breach(_ breach: BoardAutomationPartValue.Breach) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.tick) {
      HStack(spacing: 6) {
        MarkGlyph(kind: .failure, color: Color.theme.danger)
        Text(breach.heading)
      }
      .foregroundStyle(Color.theme.danger)
      ForEach(Array(breach.lines.enumerated()), id: \.offset) { _, line in
        fontResolver.text(line, base: Theme.Typography.codeSmall)
          .foregroundStyle(Color.theme.textSecondary)
      }
      Text(breach.outcome).foregroundStyle(Color.theme.textMuted)
    }
    .font(Font.theme.codeSmall)
    .lineSpacing(Self.breachLeading)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, Theme.Space.step)
    .padding(.horizontal, 10)
    .background(Color.theme.tintRed, in: RoundedRectangle(cornerRadius: 6))
  }

  private func lastText(_ last: BoardAutomationPartValue.LastText) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      BoardSectionHeader(title: last.title, below: 0) { Text(last.at) }
      fontResolver.text(last.text, base: Theme.Typography.codeCompact)
        .font(Font.theme.codeCompact)
        .foregroundStyle(Color.theme.textPrimary)
        .lineSpacing(Self.bodyLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var history: some View {
    VStack(alignment: .leading, spacing: 0) {
      BoardSectionHeader(title: .boardPartHistory, below: Theme.Space.tick) { EmptyView() }
      if card.runs.isEmpty {
        Text(l10n.string(.boardListNeverRan))
          .font(Font.theme.codeSmall)
          .foregroundStyle(Color.theme.textMuted)
          .frame(height: Self.historyLine)
      } else {
        let column = card.runs.reduce(Self.timeWidth) { width, line in
          guard case .run(let entry) = line else { return width }
          return max(
            width, fontResolver.width(entry.at, base: Theme.Typography.codeSmall).rounded(.up))
        }
        ForEach(Array(card.runs.enumerated()), id: \.offset) { _, line in
          switch line {
          case .run(let entry): run(entry, column: column)
          case .fold(let text):
            Text(text)
              .font(Font.theme.codeSmall)
              .foregroundStyle(Color.theme.textMuted)
              .frame(height: Self.historyLine)
          }
        }
      }
    }
  }

  private func run(_ entry: BoardRunEntry, column: CGFloat) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text(entry.at)
        .foregroundStyle(Color.theme.textSecondary)
        .frame(width: column, height: Self.historyLine, alignment: .leading)
      let text = fontResolver.text(entry.result, base: Theme.Typography.codeSmall)
        .foregroundStyle(BoardRunColors.result(entry.shade))
      if entry.wraps {
        text
          .lineSpacing(Self.wrapLeading)
          .padding(.vertical, 3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        text.lineLimit(1).truncationMode(.tail)
          .frame(maxWidth: .infinity, minHeight: Self.historyLine, alignment: .leading)
      }
    }
    .font(Font.theme.codeSmall)
  }

  private var buttons: some View {
    let operation = BoardAutomationHand.Operation.flow(.part)
    return HStack(spacing: 6) {
      button(key: operation.key, title: l10n.string(operation.title(paused: false)), primary: true)
      {
        model.flow(to: card.key)
      }
      button(key: nil, title: l10n.string(.boardPartAskFix), primary: false) {
        model.draftFix(of: card.key, l10n: l10n)
      }
    }
  }

  private func button(key: String?, title: String, primary: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(spacing: 6) {
        if let key { Text(key).foregroundStyle(Color.theme.accentBright) }
        Text(title).foregroundStyle(Color.theme.textPrimary)
      }
      .font(Font.theme.workspaceName)
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(
        primary ? Color.theme.tintAccent : Color.theme.surfaceInk.opacity(0.06),
        in: RoundedRectangle(cornerRadius: Theme.Radius.row)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusable(false)
  }

  private static let gap: CGFloat = 12
  private static let historyLine: CGFloat = 22
  /// 時刻の列の幅の下限（見本）。中身がこれより広ければ中身に合わせる。
  private static let timeWidth: CGFloat = 76
  /// 指示文の行の高さ 1.6（見本）に当たる行間。
  private static let bodyLeading = Theme.Typography.codeCompact.extraLeading(lineHeight: 1.6)
  /// 折り返す結果の行の高さ 18（見本）に当たる行間。
  private static let wrapLeading = Theme.Typography.codeSmall.extraLeading(
    lineHeight: 18 / Theme.Typography.codeSmall.pointSize)
  /// 形式エラーの枠の行の高さ 16（見本）に当たる行間。
  private static let breachLeading = Theme.Typography.codeSmall.extraLeading(
    lineHeight: 16 / Theme.Typography.codeSmall.pointSize)
}
