import SwiftUI

/// ボードのフッター。左に選んだ行で効くキー（↑↓ と `IntakeHand` の操作。ボタンは置かない）、右に赤の断り。自動追加が無ければ
/// キーは出さない。
struct BoardFooter: View {
  @Bindable var model: BoardIntakeModel
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.span + Theme.Space.hair) {
      if let selected = model.selected {
        PaletteKeyHint(key: "↑↓", label: l10n.string(.boardHintSelect))
        ForEach(IntakeHand.Operation.allCases, id: \.self) { operation in
          PaletteKeyHint(
            key: operation.key,
            label: l10n.string(operation.title(paused: selected.intake.paused)))
        }
      }
      Spacer(minLength: 0)
      if let refusal = model.refusal {
        Text(l10n.string(refusal.message))
          .foregroundStyle(Color.theme.danger)
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
