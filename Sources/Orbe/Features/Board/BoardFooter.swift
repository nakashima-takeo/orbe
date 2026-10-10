import SwiftUI

/// フッターの左に並べるキー 1 つ（キーと名前）。並びは部品が出す。
struct BoardKeyHint: Hashable {
  let key: String
  let label: L10nKey

  init(_ key: String, _ label: L10nKey) {
    self.key = key
    self.label = label
  }
}

/// ボードのフッター。左に焦点のある場所で効くキー（部品が出す。ボタンは置かない）、右にボードの知らせ。
struct BoardFooter: View {
  let model: BoardModel
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.span + Theme.Space.hair) {
      ForEach(model.intake.hints, id: \.self) { hint in
        PaletteKeyHint(key: hint.key, label: l10n.string(hint.label))
      }
      Spacer(minLength: 0)
      if let notice = model.notice {
        Text(l10n.string(notice.message))
          .foregroundStyle(notice.tone == .danger ? Color.theme.danger : Color.theme.textMuted)
      }
    }
    .font(Font.theme.workspaceName)
    .foregroundStyle(Color.theme.textSecondary)
    .lineLimit(1)
    .padding(.horizontal, Theme.Layout.boardInsetSide)
    .frame(height: Theme.Layout.boardFooter)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
    }
  }
}
