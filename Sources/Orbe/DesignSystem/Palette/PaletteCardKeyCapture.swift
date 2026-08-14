import SwiftUI

/// パレット内の focus 先。ちょうど 1 つに定まる（field＝入力欄 / card＝カード器）。
enum PaletteFocus { case field, card }

/// カード器を常設の first responder 候補にして ↑↓←→/↵/esc を捕捉する祖先 modifier。
/// 入力欄ありモードでは focus=.field のため子の TextField がキーを消費し、器へは
/// 子が消費しなかったキーだけ伝播する。入力欄に委ねるべき ←→（カーソル移動）と
/// ↵（IME 安全な onSubmit 確定）は fieldVisible のとき `.ignored` を返し、入力欄へ渡す。
struct PaletteCardKeyCapture: ViewModifier {
  @Bindable var model: PaletteModel
  let focus: FocusState<PaletteFocus?>.Binding

  func body(content: Content) -> some View {
    content
      .focusable()
      .focusEffectDisabled()
      .focused(focus, equals: .card)
      // 矢印は単一の catch-all に集約し ⌘ 有無で先頭/末尾ジャンプと 1 行移動を分岐する。
      .onKeyPress { press in
        switch press.key {
        case .upArrow:
          if press.modifiers.contains(.command) { model.onJumpTop() } else { model.onUp() }
          return .handled
        case .downArrow:
          if press.modifiers.contains(.command) { model.onJumpBottom() } else { model.onDown() }
          return .handled
        default:
          return .ignored
        }
      }
      .onKeyPress(.leftArrow) {
        guard !model.fieldVisible else { return .ignored }
        model.onLeft(); return .handled
      }
      .onKeyPress(.rightArrow) {
        guard !model.fieldVisible else { return .ignored }
        _ = model.onRight(); return .handled
      }
      .onKeyPress(.return) {
        guard !model.fieldVisible else { return .ignored }
        model.onActivate(); return .handled
      }
      .onKeyPress(.delete) {
        guard !model.fieldVisible else { return .ignored }
        model.onDelete(); return .handled
      }
      // ⇥ は受け手のあるモード（通知音サブパレットの試聴対象）だけが消費し、それ以外は
      // .ignored で AppKit の focus 移動へ返す（既存パレットの挙動を変えない）。
      .onKeyPress(.tab) { model.onTab() ? .handled : .ignored }
      .onKeyPress(.escape) {
        model.onEscape(); return .handled
      }
  }
}
