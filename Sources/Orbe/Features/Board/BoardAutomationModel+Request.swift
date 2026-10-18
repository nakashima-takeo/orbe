import SwiftUI

/// 依頼の欄と、修正を依頼（⌘↵）。
extension BoardAutomationModel {
  /// ⌘↵。選んでいる自動化の直しをその場で頼む。頼む相手は今のストアから引き、もう無ければ頼まずに断る。
  func askFix() {
    guard case .automation(let id) = list.selectedID else { return }
    onRefusal(nil)
    guard let automation = store.automation(id) else { return onRefusal(.boardAskFixGone) }
    ask(.automationFix(automation))
  }

  /// 欄のキー。↑↓ は段を移り、esc は ↓ と同じく一覧の先頭の行へ。⇥・⇧⇥ は何もせずに握る（焦点をボードの外へ逃がさない）。
  /// 変換中のキーは窓が IME へ渡すので、ここへは来ない。ほかは入力欄へ流す。
  func handleRequestKey(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow, .downArrow:
      guard !press.modifiers.contains(.command) else { return .ignored }
      move(press.key == .upArrow ? -1 : 1)
    case .escape:
      if press.phase == .down { move(1) }
    case .tab, .backtab:
      break
    default:
      return .ignored
    }
    return .handled
  }

  /// 欄の ↵。打った文を頼み、受けたら欄を空にする。断られたら欄を残す。空の欄は黙る。
  func send() {
    onRefusal(nil)
    if ask(.text(requestText)) { requestText = "" }
  }

  /// 頼んで、受けたかを返す。受けられなければ断りを置く。空の頼みは黙って受けない。
  @discardableResult fileprivate func ask(_ ask: SecretaryAsk) -> Bool {
    switch onAsk(ask) {
    case nil: return true
    case .claudeMissing: onRefusal(.boardAskClaudeMissing)
    case .unavailable: onRefusal(.boardAskUnavailable)
    case .empty: break
    }
    return false
  }
}
