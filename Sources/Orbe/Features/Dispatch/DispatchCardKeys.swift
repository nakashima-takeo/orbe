import SwiftUI

/// カード器を常設の first responder 候補にして clean / 最新化モードのキーを捕捉する祖先 modifier。
/// list モードでは焦点がヘッダの入力欄にあり、キーは子の `TextField` が消費するのでここへは届かない
/// （`space` が絞り込み入力に打てなくならない）。
/// 矢印は単一の catch-all に集約する（bare ハンドラが ⌘↑ を食う不確実性を構造で排除する共通規約）。
/// busy 中の畳み方は各メソッドが持つ（View で分岐しない）。
struct DispatchCardKeyCapture: ViewModifier {
  @Bindable var model: DispatchPaletteModel
  let focus: FocusState<DispatchFocus?>.Binding

  func body(content: Content) -> some View {
    content
      .focusable()
      .focusEffectDisabled()
      .focused(focus, equals: .card)
      .onKeyPress { press in
        switch model.mode {
        case .list: return .ignored
        case .clean: return cleanNavigation(press)
        case .refresh: return refreshNavigation(press)
        }
      }
      // ⏎ は画面ごとの決定・⌘⏎ は clean の実行（`onSubmit` を持たないので修飾の有無で分ける）。
      .onKeyPress { press in
        guard press.key == .return else { return .ignored }
        switch model.mode {
        case .list:
          return .ignored
        case .clean:
          if press.modifiers.contains(.command) {
            model.executeClean()
          } else {
            model.confirmClean()
          }
        case .refresh:
          model.confirmRefresh()
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
      .onKeyPress(KeyEquivalent("r")) {
        guard model.mode == .refresh else { return .ignored }
        model.retryRefresh()
        return .handled
      }
      .onKeyPress(.escape) {
        switch model.mode {
        case .list: return .ignored
        case .clean: model.exitOrCancelClean()
        case .refresh: model.exitRefresh()
        }
        return .handled
      }
  }

  private func cleanNavigation(_ press: KeyPress) -> KeyPress.Result {
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

  private func refreshNavigation(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow: model.moveRefresh(-1)
    case .downArrow: model.moveRefresh(1)
    // ⇥ は clean と同じ理由で握る。
    case .tab: break
    default: return .ignored
    }
    return .handled
  }
}
