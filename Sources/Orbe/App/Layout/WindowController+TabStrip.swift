import AppKit

extension WindowController {
  /// タブ行の投影。連の分割は `SessionStore.segments(of:)`、色番号は連の先頭タブのキーから。
  func tabStrip(of ws: Workspace) -> TabStrip {
    TabStrip(
      segments: SessionStore.segments(of: ws.tabs).map { r in
        TabStrip.Segment(
          cells: r.map { i in
            let tab = ws.tabs[i]
            return TabStrip.Cell(
              index: i, title: tab.displayTitle(workspaceRoot: ws.rootPath),
              glyph: tab.activated ? tab.agentStateKind : nil, tabId: tab.id)
          },
          colorIndex: WorktreeColor.index(forKey: ws.tabs[r.lowerBound].groupKey))
      })
  }

  /// 選択の chrome への投影（タブは位置で）。
  func chromeSelection(of ws: Workspace) -> StatusRowModel.Selection {
    switch ws.selection {
    case .empty: return .empty
    case .board: return .board
    case .tab: return ws.selectedTabIndex.map { .tab($0) } ?? .empty
    }
  }
}
