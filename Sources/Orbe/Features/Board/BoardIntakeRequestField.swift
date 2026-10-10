import AppKit
import SwiftUI

/// 自動追加の部品の依頼の欄（「❯ やりたいことを入力 … ↵ 依頼」）。打って ↵ でタスクの自動追加を頼む。
///
/// 欄に焦点が無い間は入力欄にクリックを渡さず、被せた面で受けて欄へ移る操作としてモデルに伝える——入力欄が直に焦点を取ると、
/// 地のクリックの当て直し（最後に居た場所）と行き先を取り合うため。焦点はモデルから写る。
struct BoardIntakeRequestField: View {
  @Bindable var model: BoardIntakeModel
  let focused: FocusState<BoardIntakeModel.Place?>.Binding
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
        .background(CaretAtEnd(trigger: focused.wrappedValue == .request ? model.focusToken : nil))
        .onSubmitIgnoringKeyRepeat { model.send() }
        .onKeyPress { model.handleRequestKey($0) }
        .allowsHitTesting(here)
        .overlay {
          if !here {
            Color.clear
              .contentShape(Rectangle())
              .onTapGesture { model.go(.request) }
          }
        }
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
        .strokeBorder(Color.theme.accentPrimary.opacity(0.5), lineWidth: Theme.Stroke.hairline))
  }
}

/// 欄に焦点が来たら（当て直しのたびにも）、カーソルを文の末尾へ置く。AppKit の入力欄は焦点を受けると全文を選ぶので、そのまま
/// だと打ちかけへ戻った最初の 1 字で打ちかけが消える。焦点が field editor へ写った後（次の tick）に置く。
private struct CaretAtEnd: NSViewRepresentable {
  /// 欄に焦点があるときの当て直しの番号（無ければ nil）。変わるたびに置く。
  let trigger: Int?

  func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard trigger != context.coordinator.trigger else { return }
    context.coordinator.trigger = trigger
    guard trigger != nil else { return }
    DispatchQueue.main.async {
      guard let editor = nsView.window?.firstResponder as? NSTextView else { return }
      editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var trigger: Int?
  }
}
