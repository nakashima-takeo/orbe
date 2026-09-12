import AppKit

/// 面の配置から導く読み口。
extension TerminalTab {
  /// 焦点の面の responder（端末 surface かエディター pane）。配置だけから決まり、幅に依らない。
  var focusTarget: NSView { view.focusTarget }

  /// chrome の現在地。端末焦点は実効 cwd、エディター焦点はエディターの根（worktree ルート。管理外は cwd）。
  var location: String { faces.focus == .editor ? groupKey : cwd }
}
