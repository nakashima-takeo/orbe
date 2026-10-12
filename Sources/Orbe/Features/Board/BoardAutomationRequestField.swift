import SwiftUI

/// 自動追加の部品の依頼の欄（「❯ やりたいことを入力 … ↵ 依頼」）。打って ↵ でタスクの自動追加を頼む。
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
    HStack(spacing: Theme.Space.beat) {
      Text("❯")
        .font(Font.theme.boardPrompt)
        .foregroundStyle(Color.theme.accentPrimary)
      TextField("", text: $model.requestText)
        .textFieldStyle(.plain)
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.textPrimary)
        .tint(Color.theme.accentPrimary)
        .focused(focused, equals: .request)
        .imePlaceholder(
          l10n.string(.boardAskPlaceholder),
          showWhenEmpty: model.requestText.isEmpty, focused: focused.wrappedValue == .request,
          font: Font.theme.title, color: Color.theme.textMuted
        )
        .padding(.leading, Theme.Space.hair)
        .onSubmitIgnoringKeyRepeat { model.send() }
        .onKeyPress { model.handleRequestKey($0) }
        .allowsHitTesting(here)
      Text("↵ " + l10n.string(.boardAskHint))
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.horizontal, Theme.Space.bar)
    .frame(height: Theme.Layout.boardRequest)
    .padding(Theme.Stroke.hairline)
    .background(
      Color(nsColor: Theme.Glass.surface(.help)),
      in: RoundedRectangle(cornerRadius: Theme.Radius.md)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.md)
        .strokeBorder(
          here ? Color.theme.accentPrimary.opacity(0.5) : Color.theme.inputBorder,
          lineWidth: Theme.Stroke.hairline
        )
        .animation(.linear(duration: Theme.Motion.quick), value: here)
    )
    .overlay {
      if !here {
        Color.clear
          .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
          .onTapGesture { model.go(.request) }
      }
    }
  }
}
