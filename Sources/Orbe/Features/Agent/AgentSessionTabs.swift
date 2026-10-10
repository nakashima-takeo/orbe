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

  /// 索引の材料（タブ 1 枚の会話）。
  struct Entry {
    let sessionId: String
    let tab: Tab
    let isDormant: Bool
  }

  /// タブごとの会話から作り直す。同じ会話が複数のタブにあれば、生きているタブを休眠のタブより優先し、その中では先に
  /// 来た方を取る（人が同じ会話を手で再開したとき、動いている方へ届ける）。
  func update(_ entries: [Entry]) {
    var next: [String: Tab] = [:]
    for entry in entries.filter({ !$0.isDormant }) + entries.filter(\.isDormant)
    where next[entry.sessionId] == nil {
      next[entry.sessionId] = entry.tab
    }
    if next != tabs { tabs = next }
  }
}

extension WindowController {
  /// 全タブから会話ごとのタブの索引を作り直す（`flushChrome` から。秘書の係は引く前にも）。
  func refreshAgentSessionTabs() {
    agentSessionTabs.update(
      store.allTabs().compactMap { ref in
        let tab = ref.tab
        guard let sessionId = tab.agentSlot.session?.sessionId else { return nil }
        return AgentSessionTabs.Entry(
          sessionId: sessionId,
          tab: AgentSessionTabs.Tab(
            tabId: tab.id,
            title: tab.displayTitle(workspaceRoot: workspaces[ref.workspaceIndex].rootPath)),
          isDormant: tab.isDormant)
      })
  }
}
