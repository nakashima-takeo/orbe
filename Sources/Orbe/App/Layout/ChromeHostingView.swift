import SwiftUI

/// window レベルの chrome キー配信。`window.contentView` として常在し、first responder に
/// surface が居なくても（0タブでも）`performKeyEquivalent` の view 走査で pane 非依存 chrome
/// コマンドを捕捉する。content 依存コマンド・surface 操作系は横取りせず subtree/keyDown へ流す。
final class ChromeHostingView: NSHostingView<AppShell> {
  /// pane 非依存 window コマンドのハンドラ。overlay 中は false を返して不活性化する（WindowController が配線）。
  var onWindowCommand: ((TerminalController.WindowCommand) -> Bool)?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if let command = Keybindings.chromeAction(for: event)?.windowCommand,
      command.availableWithoutTabs,
      onWindowCommand?(command) == true
    {
      return true
    }
    return super.performKeyEquivalent(with: event)  // 他は従来どおり（EditorPane の toggle 等）
  }
}
