import SwiftUI

/// ファイル内検索の欄の持ち主（面ごとに 1 つ）。欄を出している間だけ欄の状態（`SearchBarModel`）を持ち、閉じたら捨てる。
/// 上のバーの Files の中ほどは、状態があるときだけ欄を置く。欄へフォーカスを入れる要求も持つ（欄が当てて消す）。
@MainActor @Observable final class EditorFindField {
  private(set) var model: SearchBarModel?
  /// 欄へフォーカスを入れる要求（その場の 1 回きり。欄が当てたら、断られても消える。欄を閉じれば消える）。
  private(set) var focusRequested = false

  /// フォーカスが欄にあるか（欄の first responder の出入りの写し）。
  var isFocused: Bool { model?.focused == true }

  /// 欄を出す（新しい状態を作って返す）。
  func open() -> SearchBarModel {
    let model = SearchBarModel()
    self.model = model
    return model
  }

  /// 欄を閉じる（状態と要求を捨てる）。
  func close() {
    model = nil
    focusRequested = false
  }

  /// 欄へフォーカスを入れるよう求める。
  func requestFocus() {
    focusRequested = true
  }

  /// 欄が要求を当てた。
  func focusRequestDidApply() {
    focusRequested = false
  }
}

/// 上のバーのファイル内検索の欄（区切り線と、入力欄の枠 26）。入力は mono 12、右の添え物は件数（mono 11。一致なしは danger）。
/// ↵ は次、⇧↵ は前（変換の確定の ↵ では動かない）、esc は閉じる（変換中の esc は変換の取り消し）。フォーカスは要求
/// （`wantsFocus`）を欄が自分で当て、出入りを状態へ写す。フォーカスがある間だけ枠を付ける。バーの部品としては左寄せで落ちず、
/// 広がる順は `findField`——幅 0 の提案には最小の幅、本来の幅以上の提案には本来の幅、その間はその幅を使う。
struct EditorBarFindField: View {
  @Bindable var model: SearchBarModel
  var wantsFocus = false
  var focusRequestDidApply: () -> Void = {}
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: EditorBarRoot.spacing) {
      EditorBarSeparator()
      EditorFieldFrame(height: Theme.Layout.editorBarFind, isFocused: model.focused) {
        EditorTextField(
          text: model.needle, placeholder: l10n.string(.editorFindPlaceholder),
          font: Theme.Typography.editorBarFind, placeholderColor: Theme.Color.textMuted,
          wantsFocus: wantsFocus, requestDidApply: focusRequestDidApply,
          onTextChange: { model.needle = $0 }, onFocusChange: { model.focused = $0 },
          onReturn: { shift in shift ? model.onPrev?() : model.onNext?() },
          onEscape: { _ in model.onClose?() })
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
    .onChange(of: model.needle) { model.onNeedleChange?(model.needle) }
    .editorBarPart(grows: .findField)
  }
}
