import SwiftUI

/// 自動化の部品の依頼の欄（「❯ 自動化したいことを入力 … ↵ 依頼する」）。部品の上の全幅の帯に置き、打って ↵ でタスクの
/// 自動追加を頼む。
///
/// 枠は欄に焦点があるときだけ強調色で、一覧にあるときは入力欄の控えめな枠（選ばれて見えるのは常に 1 か所）。焦点を受けると
/// AppKit の入力欄の既定どおり全文が選ばれる（⌘⇧X の入力欄と同じ）。
///
/// 欄に焦点が無い間は入力欄にクリックを渡さず、枠全体に被せた面で受けて欄へ移る操作としてモデルに伝える——入力欄が直に
/// 焦点を取ると、地のクリックの当て直し（選んでいる場所）と行き先を取り合うため。焦点はモデルから写る。
struct BoardAutomationRequestField: View {
  @Bindable var model: BoardAutomationModel
  let focused: FocusState<BoardAutomationModel.Place?>.Binding
  @Environment(\.localization) private var l10n

  var body: some View {
    let here = model.place == .request
    HStack(spacing: Self.gap) {
      Text(verbatim: "❯")
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.accentPrimary)
      TextField("", text: $model.requestText)
        .textFieldStyle(.plain)
        .font(Font.theme.code)
        .foregroundStyle(Color.theme.textPrimary)
        .tint(Color.theme.accentPrimary)
        .focused(focused, equals: .request)
        .imePlaceholder(
          BoardAutomationExamples.placeholder(l10n),
          showWhenEmpty: model.requestText.isEmpty, focused: focused.wrappedValue == .request,
          font: Font.theme.code, color: Color.theme.textMuted
        )
        .onSubmitIgnoringKeyRepeat { model.send() }
        .onKeyPress { model.handleRequestKey($0) }
        .allowsHitTesting(here)
      Text("↵ " + l10n.string(.boardAskHint))
        .font(Font.theme.codeSmall)
        .foregroundStyle(here ? Color.theme.textSecondary : Color.theme.textMuted)
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.horizontal, Self.inset)
    .frame(height: Self.height)
    .padding(Theme.Stroke.hairline)
    .background(Color.theme.inputWash, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.row)
        .strokeBorder(
          here ? Color.theme.accentPrimary.opacity(0.5) : Color.theme.inputBorder,
          lineWidth: Theme.Stroke.hairline
        )
        .animation(.linear(duration: Theme.Motion.quick), value: here)
    )
    .overlay {
      if !here {
        Color.clear
          .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
          .onTapGesture { model.go(.request) }
      }
    }
    .padding(.vertical, Theme.Space.beat)
    .padding(.horizontal, Theme.Space.bar)
    .padding(.bottom, Theme.Stroke.hairline)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
    }
  }

  /// 枠の内側の高さ。
  private static let height: CGFloat = 36
  private static let inset: CGFloat = 14
  private static let gap: CGFloat = 10
}
