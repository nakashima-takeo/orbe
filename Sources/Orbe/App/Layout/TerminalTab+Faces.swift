import AppKit

/// 面の配置から導く読み口。
extension TerminalTab {
  /// 焦点の面の responder（端末 surface かエディター pane）。配置だけから決まり、幅に依らない。
  var focusTarget: NSView { view.focusTarget }

  /// chrome の現在地（事実。表現は chrome が持つ）。端末焦点は cwd 1 本、エディター焦点で根の下の文書は
  /// 根と相対パス、根の外の文書は絶対パス、文書が無ければ根だけ。
  enum Location: Equatable {
    case path(String)
    case root(String)
    case file(root: String, relative: String)
  }

  var location: Location {
    guard faces.focus == .editor else { return .path(cwd) }
    guard let path = MainActor.assumeIsolated({ editor.activeDocument?.url.path }) else {
      return .root(groupKey)
    }
    guard path.hasPrefix(groupKey + "/") else { return .path(path) }
    return .file(root: groupKey, relative: String(path.dropFirst(groupKey.count + 1)))
  }
}
