import SwiftUI

/// 入力欄が受けるキー（一覧とベースを選ぶ画面）。握らないキーは焦点が入力欄から外へ逃げ、↑↓ と打鍵が
/// 効かなくなるので、⇥・⇧⇥ はどちらの画面でも握る。矢印は単一の catch-all で ⌘ 有無を分ける
/// （bare ハンドラが ⌘↑ を食う不確実性を構造で排除する共通規約）。入力ロック中はどれも握り潰す。
enum WorktreePaletteFieldKeys {
  static func handle(_ press: KeyPress, model: WorktreePaletteModel) -> KeyPress.Result {
    switch model.mode {
    case .list: list(press, model)
    case .basePicker: basePicker(press, model)
    case .clean, .refresh: .ignored
    }
  }

  /// ⇧⇥ は `.tab` に shift が付いた形と、AppKit の backtab 文字の形のどちらでも届きうる。
  private static func isBacktab(_ press: KeyPress) -> Bool {
    (press.key == .tab && press.modifiers.contains(.shift)) || press.key.character == "\u{19}"
  }

  private static func list(_ press: KeyPress, _ model: WorktreePaletteModel) -> KeyPress.Result {
    let locked = model.isLocked
    if isBacktab(press) {
      if !locked { model.cycleBase() }
      return .handled
    }
    switch press.key {
    case .upArrow, .downArrow:
      guard !locked else { return .handled }
      let direction = press.key == .upArrow ? -1 : 1
      if press.modifiers.contains(.command) { model.jump(direction) } else { model.move(direction) }
    case .tab:
      if !locked { model.cycleTarget() }
    case .escape:
      if !locked { model.onDismiss() }
    default:
      return .ignored
    }
    return .handled
  }

  private static func basePicker(_ press: KeyPress, _ model: WorktreePaletteModel)
    -> KeyPress.Result
  {
    if isBacktab(press) { return .handled }
    switch press.key {
    case .upArrow: model.basePicker?.move(-1)
    case .downArrow: model.basePicker?.move(1)
    case .tab: break
    case .escape: model.exitBasePicker()
    default: return .ignored
    }
    return .handled
  }
}
