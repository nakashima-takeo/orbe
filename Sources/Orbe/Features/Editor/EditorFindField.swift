import SwiftUI

/// ファイル内検索の欄の持ち主（面ごとに 1 つ）。欄を出している間だけ欄の状態（`SearchBarModel`）を持ち、閉じたら捨てる。
/// 上のバーの Files の中ほどは、状態があるときだけ欄を置く。
@MainActor @Observable final class EditorFindField {
  private(set) var model: SearchBarModel?

  /// フォーカスが欄にあるか（欄の状態が持つ、view のフォーカスの写し）。
  var isFocused: Bool { model?.focused == true }

  /// 欄を出す（新しい状態を作って返す）。
  func open() -> SearchBarModel {
    let model = SearchBarModel()
    self.model = model
    return model
  }

  /// 欄を閉じる（状態を捨てる）。
  func close() {
    model = nil
  }
}

/// 上のバーのファイル内検索の欄（区切り線と、入力欄の枠 26）。入力は mono 12、右の添え物は件数（mono 11。一致なしは danger）。
/// ↵ は次、⇧↵ は前（変換の確定の ↵ では動かない）、esc は閉じる。フォーカスは状態の要求（`focusToken`。0 なら要求なし）を
/// 見て入れ、出入りを状態へ写す。フォーカスがある間だけ枠を付ける。バーの部品としては左寄せで落ちず、広がる順は
/// `findField`——幅 0 の提案には最小の幅、本来の幅以上の提案には本来の幅、その間はその幅を使う。
struct EditorBarFindField: View {
  @Bindable var model: SearchBarModel
  @Environment(\.localization) private var l10n
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: EditorBarRoot.spacing) {
      EditorBarSeparator()
      EditorFieldFrame(height: Theme.Layout.editorBarFind, isFocused: model.focused) {
        TextField("", text: $model.needle)
          .textFieldStyle(.plain)
          .font(Font.theme.editorBarFind)
          .foregroundStyle(Color.theme.textPrimary)
          .tint(Color.theme.accentPrimary)
          .lineLimit(1)
          .focused($isFocused)
          .accessibilityLabel(l10n.string(.editorFindPlaceholder))
          .imePlaceholder(
            l10n.string(.editorFindPlaceholder), showWhenEmpty: model.needle.isEmpty,
            focused: isFocused, font: Font.theme.editorBarFind, color: Color.theme.textMuted
          )
          .onSubmit { model.onNext?() }
          .onKeyPress { press in
            guard press.key == .return, press.modifiers.contains(.shift) else { return .ignored }
            model.onPrev?()
            return .handled
          }
          .onKeyPress(.escape) {
            model.onClose?()
            return .handled
          }
      } accessory: {
        if let count = model.countText(l10n) {
          Text(count)
            .font(Font.theme.editorBarFindCount)
            .foregroundStyle(model.countIsNoMatch ? Color.theme.danger : Color.theme.textMuted)
            .lineLimit(1)
            .fixedSize()
            .padding(.trailing, Theme.Layout.editorBarFindCountTrailing)
        }
      }
      .frame(
        minWidth: Theme.Layout.editorBarFindMinWidth, idealWidth: Theme.Layout.editorBarFindWidth,
        maxWidth: Theme.Layout.editorBarFindWidth)
    }
    .onChange(of: isFocused) { model.focused = isFocused }
    .onChange(of: model.needle) { model.onNeedleChange?(model.needle) }
    .onChange(of: model.focusToken, initial: true) { if model.focusToken > 0 { isFocused = true } }
    .editorBarPart(grows: .findField)
  }
}
