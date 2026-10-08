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

  private static func list(_ press: KeyPress, _ model: WorktreePaletteModel) -> KeyPress.Result {
    let locked = model.isLocked
    switch press.key {
    case .upArrow, .downArrow:
      guard !locked else { return .handled }
      let direction = press.key == .upArrow ? -1 : 1
      if press.modifiers.contains(.command) { model.jump(direction) } else { model.move(direction) }
    case .tab:
      if !locked { model.cycleTarget() }
    case .backtab:
      if !locked { model.cycleBase() }
    case .escape:
      if !locked { model.onDismiss() }
    case _ where isBackspace(press):
      // 入力欄が空の ⌫ はタスクの札を外す（文字があるときは文字を消す）。押し続けたキーリピートでは外さない。
      guard model.query.isEmpty, model.taskContextID != nil else { return .ignored }
      if press.phase == .down { model.clearTaskContext() }
    default:
      return .ignored
    }
    return .handled
  }

  /// 修飾なしの ⌫。実機のキーは function 等の修飾を伴うことがあるので、修飾の集合が空かでは判定しない。
  private static func isBackspace(_ press: KeyPress) -> Bool {
    press.key == .backspace
      && press.modifiers.isDisjoint(with: [.command, .option, .control, .shift])
  }

  private static func basePicker(_ press: KeyPress, _ model: WorktreePaletteModel)
    -> KeyPress.Result
  {
    switch press.key {
    case .upArrow: model.basePicker?.move(-1)
    case .downArrow: model.basePicker?.move(1)
    case .tab, .backtab: break
    case .escape: model.exitBasePicker()
    default: return .ignored
    }
    return .handled
  }
}
