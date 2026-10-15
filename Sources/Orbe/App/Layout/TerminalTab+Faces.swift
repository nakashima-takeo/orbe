import AppKit

/// 面の配置から導く読み口と、配置を変える操作。
extension TerminalTab {
  /// ⌘⇧F。エディターを見せ（隠れていれば全面、見えていれば焦点だけ——`open_file` と同じ規則）、サイドバーを検索パネルで
  /// 開いて入力欄に焦点を入れる。種は押した時点の焦点で決めるので、配置を変える前に取る。
  func findInProject() {
    let pane = view.editor
    let seed = pane.projectSearchSeed()
    let ratio = faces.editorRatio == 0 ? 1 : faces.editorRatio
    setFaces(FaceLayout(editorRatio: ratio, focus: .editor), animated: true)
    pane.showProjectSearch(seed: seed)
  }

  /// 焦点の面の responder（端末 surface かエディター pane）。配置だけから決まり、幅に依らない。
  var focusTarget: NSView { view.focusTarget }

  /// chrome の現在地（事実。表現は chrome が持つ）。端末焦点は cwd 1 本、エディター焦点で根の下のファイル（文書のタブ・
  /// diff のタブ）は根と相対パス、根の外のファイルは絶対パス、タブが無ければ根だけ。cwd と根の外の絶対パスは別の事実
  /// （常態の居場所と、根から外れたファイル）で、chrome は別のトーンで描く。
  enum Location: Equatable {
    case cwd(String)
    case root(String)
    case file(root: String, relative: String)
    case absolute(String)
  }

  var location: Location {
    guard faces.focus == .editor else { return .cwd(cwd) }
    guard let path = MainActor.assumeIsolated({ editor.activeTab?.url.path }) else {
      return .root(groupKey)
    }
    guard path.hasPrefix(groupKey + "/") else { return .absolute(path) }
    return .file(root: groupKey, relative: String(path.dropFirst(groupKey.count + 1)))
  }
}
