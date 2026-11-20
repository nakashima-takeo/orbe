import SwiftUI

/// 依頼の欄。
extension BoardAutomationModel {
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
    if ask(requestText) { requestText = "" }
  }

  /// 頼んで、受けたかを返す。受けられなければ断りを置く。空の頼みは黙って受けない。
  private func ask(_ ask: String) -> Bool {
    switch onAsk(ask) {
    case nil: return true
    case .claudeMissing: onRefusal(.boardAskClaudeMissing)
    case .unavailable: onRefusal(.boardAskUnavailable)
    case .empty: break
    }
    return false
  }

  /// カードの「修正を依頼」。依頼の欄に「自動化「<名前>」のノード「<名前>」の修正：」を書き（書きかけは置き換える）、焦点を欄へ
  /// 移す——続けて打って ↵ で、欄からふつうに頼む。`l10n` は画面の言語。
  func draftFix(of nodeId: AutomationNodeID, l10n: LocalizationStore) {
    guard let automation = selectedAutomation, let node = automation.graph.node(nodeId) else {
      return
    }
    draft(l10n.format(.boardAskFixDraft, automation.name, node.entity.name))
  }

  /// 定義を読めない自動化の「修正を依頼」。依頼の欄に「自動化「<名前>」の修正：<理由の原文>」を書く（読むのは AI なので
  /// 原文だけ）。
  func draftFixOfUnreadable(l10n: LocalizationStore) {
    guard let broken = selectedUnreadable else { return }
    draft(
      l10n.format(.boardAskFixAutomationDraft, BoardAutomationStanding(broken).title(l10n))
        + broken.reason)
  }
}
