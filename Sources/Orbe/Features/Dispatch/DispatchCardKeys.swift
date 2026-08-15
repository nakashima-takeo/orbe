import SwiftUI

/// カード器を常設の first responder 候補にして clean モードのキーを捕捉する祖先 modifier。
/// list モードでは焦点がヘッダの入力欄にあり、キーは子の `TextField` が消費するのでここへは届かない
/// （`space` が絞り込み入力に打てなくならない）。
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
        // ←→ はブランチの扱い。効くのはサブラインが開いている行だけ（畳みはモデルが持つ）。
        case .leftArrow: model.clean.chooseBranch(.keep)
        case .rightArrow: model.clean.chooseBranch(.delete)
        // clean に ⇥ の意味は無いが、握らないと焦点がカード器から抜けて以下のキーが全部死ぬ
        // （list 側の入力欄が同じ理由で ⇥ を握っているのと同じ手当て）。
        case .tab: break
        default: return .ignored
        }
        return .handled
      }
      // ⏎ は画面ごとの決定・⌘⏎ は実行（`onSubmit` を持たないので修飾の有無で分ける）。
      .onKeyPress { press in
        guard model.mode == .clean, press.key == .return else { return .ignored }
        if press.modifiers.contains(.command) {
          model.executeClean()
        } else {
          model.confirmClean()
        }
        return .handled
      }
      .onKeyPress(.space) {
        guard model.mode == .clean else { return .ignored }
        model.clean.toggleAtCursor()
        return .handled
      }
      .onKeyPress(KeyEquivalent("o")) {
        guard model.mode == .clean else { return .ignored }
        model.openCleanFailure()
        return .handled
      }
      .onKeyPress(.escape) {
        guard model.mode == .clean else { return .ignored }
        model.exitOrCancelClean()
        return .handled
      }
  }
}
