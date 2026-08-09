import SwiftUI

/// カード器を常設の first responder 候補にして clean モードのキーを捕捉する祖先 modifier。
/// list モードでは焦点がヘッダの入力欄にあり、キーは子の `TextField` が消費するのでここへは届かない
/// （`space` と `a` が絞り込み入力に打てなくならない）。
/// 矢印は単一の catch-all に集約する（bare ハンドラが ⌘↑ を食う不確実性を構造で排除する共通規約）。
struct DispatchCardKeyCapture: ViewModifier {
  @Bindable var model: DispatchPaletteModel
  let focus: FocusState<DispatchFocus?>.Binding

  func body(content: Content) -> some View {
    content
      .focusable()
      .focusEffectDisabled()
      .focused(focus, equals: .card)
      .onKeyPress { press in
        guard model.mode == .clean else { return .ignored }
        switch press.key {
        case .upArrow: model.clean.move(-1)
        case .downArrow: model.clean.move(1)
        default: return .ignored
        }
        return .handled
      }
      // ⏎ は選択を 1 つ進める・⌘⏎ は実行（`onSubmit` を持たないので修飾の有無で分ける）。
      .onKeyPress { press in
        guard model.mode == .clean, press.key == .return else { return .ignored }
        if press.modifiers.contains(.command) {
          model.executeClean()
        } else {
          model.clean.advance()
        }
        return .handled
      }
      .onKeyPress(.space) {
        guard model.mode == .clean else { return .ignored }
        model.clean.advance()
        return .handled
      }
      .onKeyPress(KeyEquivalent("a")) {
        guard model.mode == .clean else { return .ignored }
        model.clean.selectAllSafe()
        return .handled
      }
      .onKeyPress(.escape) {
        guard model.mode == .clean else { return .ignored }
        model.exitClean()
        return .handled
      }
  }
}
