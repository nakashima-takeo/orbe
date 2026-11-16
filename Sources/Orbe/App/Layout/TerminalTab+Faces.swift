import AppKit

/// 連の面の配置から導く、このタブの読み口。
extension TerminalTab {
  /// 焦点の面の responder。連の焦点がエディターならその pane の行き先、端末ならこのタブの端末 surface。配置だけから
  /// 決まり、幅に依らない。
  var focusTarget: NSView {
    group.faces.focus == .editor ? group.view.editor.focusTarget : surface
  }

  /// chrome の現在地（事実。表現は chrome が持つ）。端末焦点は cwd 1 本、エディター焦点で根の下のファイル（文書のタブ・
  /// 作業ツリーとステージ済みの diff のタブ）は根と相対パス、PR の diff のタブは PR の番号と相対パス、根の外のファイルは
  /// 絶対パス、タブが無ければ根だけ。cwd と根の外の絶対パスは別の事実
  /// （常態の居場所と、根から外れたファイル）で、chrome は別のトーンで描く。
  enum Location: Equatable {
    case cwd(String)
    case root(String)
    case file(root: String, relative: String)
    case absolute(String)
    /// PR の diff（PR の番号と、根からの相対パス）。
    case pullRequest(number: Int, relative: String)
  }

  var location: Location {
    guard group.faces.focus == .editor else { return .cwd(cwd) }
    let root = group.key
    let active = MainActor.assumeIsolated { () -> (path: String, pullRequest: Int?)? in
      guard let tab = group.editor.activeTab else { return nil }
      if case .diff(let diff) = tab, case .pullRequest(let state) = diff.id.kind {
        return (diff.id.path, state.key.id.number)
      }
      return (tab.url.path, nil)
    }
    guard let active else { return .root(root) }
    if let number = active.pullRequest {
      return .pullRequest(number: number, relative: active.path)
    }
    guard active.path.hasPrefix(root + "/") else { return .absolute(active.path) }
    return .file(root: root, relative: String(active.path.dropFirst(root.count + 1)))
  }
}
