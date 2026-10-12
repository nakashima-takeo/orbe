import AppKit

/// 連の面の配置から導く、このタブの読み口。
extension TerminalTab {
  /// 焦点の面の responder。連の焦点がエディターならその pane の行き先、端末ならこのタブの端末 surface。配置だけから
  /// 決まり、幅に依らない。
  var focusTarget: NSView {
    group.faces.focus == .editor ? group.view.editor.focusTarget : surface
  }

  /// chrome の現在地（事実。表現は chrome が持つ）。端末焦点は cwd 1 本、エディター焦点で根の下の文書は
  /// 根と相対パス、根の外の文書は絶対パス、文書が無ければ根だけ。cwd と根の外の絶対パスは別の事実
  /// （常態の居場所と、根から外れた文書）で、chrome は別のトーンで描く。
  enum Location: Equatable {
    case cwd(String)
    case root(String)
    case file(root: String, relative: String)
    case absolute(String)
  }

  var location: Location {
    guard group.faces.focus == .editor else { return .cwd(cwd) }
    let root = group.key
    guard let path = MainActor.assumeIsolated({ group.editor.activeDocument?.url.path }) else {
      return .root(root)
    }
    guard path.hasPrefix(root + "/") else { return .absolute(path) }
    return .file(root: root, relative: String(path.dropFirst(root.count + 1)))
  }
}
