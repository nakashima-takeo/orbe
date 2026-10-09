import SwiftUI

/// 入力欄の下の行き先の段（「行き先 [↵ タスクに書く 既定] [⌘↵ ◐ 秘書に頼む]」と、右端に足したタスクが入る先）。
/// 入力欄に文字がある間だけ出る。選択の同一性の入力の行き先（`TaskPaletteRowID.add`）の見せ方で、それが選ばれている
/// 間だけ「タスクに書く」が枠付きで光る。切り替えの状態は持たない（2 つのキー）——開くたびに ↵ はタスクに書く。
struct TaskPaletteDestinationBar: View {
  @Bindable var model: TaskPaletteModel
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Space.step) {
      Text(l10n.string(.taskPaletteDestination))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .padding(.trailing, Theme.Space.beat)
      button(
        lit: model.selectedID == .add, action: { model.tapRow(.add) },
        label: {
          Text("↵").foregroundStyle(Color.theme.textMuted)
          Text(l10n.string(.taskPaletteDestinationTask)).foregroundStyle(Color.theme.textPrimary)
          Text(l10n.string(.taskPaletteDestinationDefault))
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.accentBright)
        })
      button(
        lit: false, action: { model.askWithQuery() },
        label: {
          Text("⌘↵").foregroundStyle(Color.theme.textMuted)
          SecretaryMark(size: 10)
          Text(l10n.string(.taskPaletteAskSecretary)).foregroundStyle(Color.theme.textPrimary)
        })
      Spacer(minLength: Theme.Space.step)
      Text(model.destinationPlace(l10n))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.head)
    }
    .padding(.horizontal, Theme.Space.span)
    .frame(height: Self.height)
  }

  /// 段の高さ（ボタン 30 ＋ 上下の余白）。
  static let height: CGFloat = 48

  private func button<Label: View>(
    lit: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label
  ) -> some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.row)
    return Button(action: action) {
      HStack(spacing: Theme.Space.note, content: label)
        .font(Font.theme.workspaceName)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Theme.Space.beat)
        .frame(height: 30)
        .background(shape.fill(lit ? Color.theme.tintAccent : .clear))
        .overlay(
          shape.strokeBorder(
            lit ? Color.theme.accentPrimary.opacity(0.7) : Color.theme.surface1,
            lineWidth: Theme.Stroke.hairline)
        )
        .contentShape(shape)
    }
    .buttonStyle(.plain)
    .focusable(false)
  }
}

/// 秘書の印（Orbe の印）。
struct SecretaryMark: View {
  let size: CGFloat

  var body: some View {
    OrbeMarkShape()
      .fill(Color.theme.glyphGradient, style: FillStyle(eoFill: true))
      .frame(width: size, height: size)
  }
}
