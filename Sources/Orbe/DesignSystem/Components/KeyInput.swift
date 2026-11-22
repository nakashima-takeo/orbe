import SwiftUI

/// 画面のモデルが受ける 1 打鍵。修飾キーは ⌘⌥⌃⇧ だけを持つ——実機の矢印キーは numericPad と function のフラグを伴って届き、
/// CapsLock も修飾キーの集合に載るが、どれも押している修飾キーではない。
struct KeyInput {
  let key: KeyEquivalent
  let modifiers: EventModifiers
  /// 押し続けて起きたキーリピートか。
  let isRepeat: Bool

  init(_ key: KeyEquivalent, modifiers: EventModifiers = [], isRepeat: Bool = false) {
    self.key = key
    self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
    self.isRepeat = isRepeat
  }
}

extension KeyInput {
  init(_ press: KeyPress) {
    self.init(press.key, modifiers: press.modifiers, isRepeat: press.phase != .down)
  }
}
