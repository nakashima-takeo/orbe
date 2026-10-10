import Foundation

@testable import Orbe

/// 連を問わないテストのタブ。自分だけの連に属し、端末をその連の器に差して見せる（器を窓に付ければ surface が生まれる）。
/// 同じ連のタブを並べるテストは `TerminalTab(cwd:group:)` に同じ連を渡す。
extension TerminalTab {
  static func alone(
    cwd: String, command: String? = nil, env: [String: String] = [:],
    editorSurfaces: EditorSurfaces = .shared
  ) -> TerminalTab {
    let group = TabGroup(key: GitWorktreeRoot.root(of: cwd), editorSurfaces: editorSurfaces)
    return seated(TerminalTab(cwd: cwd, group: group, command: command, env: env))
  }

  static func alone(
    restoring state: TabState, resumeSpawn: @escaping ResumeSpawn,
    editorSurfaces: EditorSurfaces = .shared
  ) -> TerminalTab {
    let group = TabGroup(key: GitWorktreeRoot.root(of: state.cwd), editorSurfaces: editorSurfaces)
    return seated(TerminalTab(restoring: state, group: group, resumeSpawn: resumeSpawn))
  }

  private static func seated(_ tab: TerminalTab) -> TerminalTab {
    tab.group.view.add(terminal: tab.terminal)
    tab.group.view.show(terminal: tab.terminal)
    return tab
  }
}
