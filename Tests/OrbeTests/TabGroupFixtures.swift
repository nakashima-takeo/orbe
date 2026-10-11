import Foundation

@testable import Orbe

/// 連を問わないテストのタブ。自分だけの連に属する。同じ連のタブを並べるテストは `TerminalTab(cwd:group:)` に同じ連を渡す。
extension TerminalTab {
  /// 端末をその連の器に差して見せる（器を窓に付ければ surface が生まれる）。
  static func alone(cwd: String, editorSurfaces: EditorSurfaces = .shared) -> TerminalTab {
    let group = TabGroup(key: GitWorktreeRoot.root(of: cwd), editorSurfaces: editorSurfaces)
    let tab = TerminalTab(cwd: cwd, group: group)
    group.view.add(terminal: tab.terminal)
    group.view.show(terminal: tab.terminal)
    return tab
  }

  /// 休眠のまま。端末は器に差さない（器に入るのは起きたタブの端末だけ）。
  static func alone(restoring state: TabState, resumeSpawn: @escaping ResumeSpawn) -> TerminalTab {
    TerminalTab(
      restoring: state, group: TabGroup(key: GitWorktreeRoot.root(of: state.cwd)),
      resumeSpawn: resumeSpawn)
  }
}
