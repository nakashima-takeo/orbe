import Foundation
import Observation

/// 会話（セッション ID）ごとの、それを持つタブ（@Observable・main のみ・窓に 1 つ）。タブは観測できない値なので、
/// chrome の更新の合流点（`flushChrome`）が全タブからこの索引を作り直し、値が変わったときだけ書く
/// （`WorktreeAgentActivity` と同じ作り方）。タスク画面の会話の行と、解けた待ちの ⌘T が読む（⌘T はここでタブを
/// 引き、届け方はその時点のタブの状態で決める）。休眠のタブも載る。
@Observable final class AgentSessionTabs {
  struct Tab: Equatable {
    let tabId: Int
    /// タブの表示名。
    let title: String
  }

  /// セッション ID → そのタブ。
  private(set) var tabs: [String: Tab]

  init(tabs: [String: Tab] = [:]) {
    self.tabs = tabs
  }

  /// タブごとの (セッション ID, タブ) から作り直す。同じ会話が複数のタブにあれば、先に来た方を取る。
  func update(_ entries: [(sessionId: String, tab: Tab)]) {
    var next: [String: Tab] = [:]
    for (sessionId, tab) in entries where next[sessionId] == nil { next[sessionId] = tab }
    if next != tabs { tabs = next }
  }
}

extension WindowController {
  /// 全タブから会話ごとのタブの索引を作り直す（`flushChrome` から）。
  func refreshAgentSessionTabs() {
    agentSessionTabs.update(
      store.allTabs().compactMap { ref in
        let tab = ref.tab
        guard let sessionId = tab.agentSlot.session?.sessionId else { return nil }
        return (
          sessionId,
          AgentSessionTabs.Tab(
            tabId: tab.id,
            title: tab.displayTitle(workspaceRoot: workspaces[ref.workspaceIndex].rootPath))
        )
      })
  }
}
