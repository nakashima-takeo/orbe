import SwiftUI

/// window レベルの chrome キー配信。`window.contentView` として常在し、first responder に
/// surface が居なくても（0タブでも）`performKeyEquivalent` の view 走査でタブ非依存 chrome
/// コマンドを捕捉する。content 依存コマンド・surface 操作系は横取りせず subtree/keyDown へ流す。
///
/// その前に、焦点の受け手が変換中なら ⌘ 付きのキーをまず IME へ渡す（`InputMethodKeyEquivalents`）。IME が使わなければ
/// 今の順（タブ非依存 window コマンド → 配下の view → pane → メニュー → keyDown）で流れる。
final class ChromeHostingView: NSHostingView<AppShell> {
  /// タブ非依存 window コマンドのハンドラ。overlay 中は false を返して不活性化する（WindowController が配線）。
  var onWindowCommand: ((WindowCommand) -> Bool)?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.contains(.command),
      let receiver = window?.firstResponder as? InputMethodKeyEquivalents,
      receiver.offerKeyEquivalentToInputMethod(event)
    {
      return true
    }
    if let command = Keybindings.chromeAction(for: event)?.windowCommand,
      command.availableWithoutTabs,
      onWindowCommand?(command) == true
    {
      return true
    }
    return super.performKeyEquivalent(with: event)  // 他は従来どおり（⌘R のリネーム等）
  }
}
