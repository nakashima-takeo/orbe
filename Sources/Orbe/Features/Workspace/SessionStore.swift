import Foundation

/// タブ閉鎖の発火源。閉鎖経路（surface・libghostty ランタイム・制御 API）から
/// `TerminalTab.close` → `onClose` → `WindowController.closeTab` → `SessionStore.removeTab`
/// まで素通しで届き、開き直しスタック（⇧⌘T）へ積むかの判定に入る。
/// デフォルト値を持たせない＝全呼び出し元が発火源を明示することをコンパイラが強制する。
enum TabCloseOrigin {
  /// 人のジェスチャ（タブ行の中クリック・⌘W）。
  case gesture
  /// シェル exit・エージェント終了（libghostty の close_surface_cb）。
  case process
  /// 制御 API（close_tab）。
  case controlAPI

  /// 人が自分の意思でタブを畳んだ閉鎖か（外から落ちた閉鎖と分ける）。
  /// 網羅 switch（default 無し）＝閉鎖経路が増えたとき分類漏れをコンパイルエラーで検出する。
  var isHumanGesture: Bool {
    switch self {
    case .gesture: return true
    case .process, .controlAPI: return false
    }
  }
}

/// 走査で得た 1 タブと、その居場所（workspace / タブの index）。
/// `SessionStore.allTabs()` の要素で、制御 API の列挙と Dispatch の cwd 突合が共有する。
struct TabRef {
  let workspaceIndex: Int
  let tabIndex: Int
  let tab: TerminalTab
}

/// 閉じたエージェントタブ 1 枚の開き直しエントリ。`index` は閉じた時点のタブ位置。
struct ClosedAgentTab {
  let index: Int
  let state: TabState
}

/// ドメイン/セッション状態（`workspaces` と `activeWorkspace`）の唯一の所有者。
/// 配列の CRUD・active index 補正・MRU 退避先選定・workspace の index 演算といった純ドメイン
/// ロジックだけを持ち、ビューの mount/reparent や chrome 投影は WindowController に残す。
/// Foundation のみに依存する（同モジュール型 `Workspace`/`TerminalTab` の名前参照は
/// フレームワーク import を要さない）。
final class SessionStore {
  private(set) var workspaces: [Workspace]
  private(set) var activeWorkspace: Int
  var current: Workspace { workspaces[activeWorkspace] }

  /// 開き直しスタックの上限（workspace ごと）。数件戻せれば足りる用途で、閉じたタブの
  /// スナップショットを無制限に抱え込まないための上限。
  private static let closedAgentTabLimit = 10

  init(workspaces: [Workspace] = [], activeWorkspace: Int = 0) {
    self.workspaces = workspaces
    self.activeWorkspace = activeWorkspace
  }

  /// 復元/初期化で組み立て済みの配列一式を差し替える（WindowController.init が wire 後に渡す）。
  func load(workspaces: [Workspace], activeWorkspace: Int) {
    self.workspaces = workspaces
    self.activeWorkspace = activeWorkspace
  }

  // MARK: - 純ドメイン読み

  /// 指定 workspace のアクティブタブの実効 cwd（`TerminalTab.cwd`）。0タブは nil。
  /// workspace index の妥当性は呼び出し側が保証する。
  private func tabCwd(inWorkspaceAt i: Int) -> String? {
    let ws = workspaces[i]
    guard ws.tabs.indices.contains(ws.active) else { return nil }
    return ws.tabs[ws.active].cwd
  }

  /// アクティブ workspace のアクティブタブの実効 cwd。0タブは nil。
  func activeTabCwd() -> String? { tabCwd(inWorkspaceAt: activeWorkspace) }

  /// 全 workspace × 全タブ（**休眠 workspace も含む**）。
  /// 休眠タブは `currentPwd` を持たないが `initialCwd`（復元値）は持つので、cwd の話には必ず含める。
  func allTabs() -> [TabRef] {
    workspaces.enumerated().flatMap { wi, ws in
      ws.tabs.enumerated().map { ti, tab in TabRef(workspaceIndex: wi, tabIndex: ti, tab: tab) }
    }
  }

  /// 指定 workspace での新規タブ起動の初期 cwd（GUI・エージェント起動・制御 API のすべてが
  /// `openTab` 越しにここを通る）。
  /// 当該 workspace のアクティブタブの cwd を継ぎ、タブ不在（0タブ）はその workspace の rootPath
  /// へ落とす。nil を surface へ渡すと ghostty がホームへ解決してしまうため、ここで必ず確定させる。
  /// workspace index の妥当性は呼び出し側が保証する。
  func newTabCwd(inWorkspaceAt i: Int) -> String {
    tabCwd(inWorkspaceAt: i) ?? workspaces[i].rootPath
  }

  // MARK: - select のブックキーピング（ビューは触らない）

  /// owner を確認してから、tab の materialize 開始を記録する。
  /// workspace の activated は配下の tab 状態から導出されるため、別の書込みは持たない。
  @discardableResult func recordMaterialization(of tab: TerminalTab, in workspace: Workspace)
    -> Bool
  {
    guard workspaces.contains(where: { $0 === workspace }),
      workspace.tabs.contains(where: { $0 === tab })
    else { return false }
    tab.recordMaterializationStarted()
    return true
  }

  /// workspace を前面で利用した履歴を記録する。materialize 状態とは独立し、0タブでも MRU を進める。
  @discardableResult func recordWorkspaceUse(_ workspace: Workspace) -> Bool {
    guard workspaces.contains(where: { $0 === workspace }) else { return false }
    workspace.lastUsedAt = Date()
    return true
  }

  /// タブ選択のドメイン記録。index ガード → workspace の MRU → `active` の順で進め、成否を返す。
  /// ビュー除去/mount/focus/chrome は呼び出し側（WindowController.select）が担う。
  @discardableResult func recordSelection(_ index: Int) -> Bool {
    guard current.tabs.indices.contains(index) else { return false }
    let ws = current
    recordWorkspaceUse(ws)
    ws.active = index
    return true
  }

  /// 次タブ index（`(active+1)%n`）。タブ空は nil。
  func nextTabIndex() -> Int? {
    let n = current.tabs.count
    guard n > 0 else { return nil }
    return (current.active + 1) % n
  }

  /// 前タブ index（`(active-1+n)%n`）。タブ空は nil。
  func prevTabIndex() -> Int? {
    let n = current.tabs.count
    guard n > 0 else { return nil }
    return (current.active - 1 + n) % n
  }

  // MARK: - タブ CRUD（domain）

  /// アクティブ workspace の `index`（有効範囲 0…count へクランプ）へタブを挿し、実挿入 index を返す。
  /// 挿入位置が現 active 以前なら active を 1 つ繰り下げ、挿入前と同じタブを指し続けさせる
  /// （呼び出し側が直後に select する前提に寄りかからず、store 単体で不変条件を保つ）。
  func insertTabIntoActive(_ tab: TerminalTab, at index: Int) -> Int {
    let ws = current
    let dest = min(max(0, index), ws.tabs.count)
    ws.tabs.insert(tab, at: dest)
    if dest <= ws.active { ws.active += 1 }
    ws.active = min(ws.active, ws.tabs.count - 1)  // 0タブへの挿入（active=0・count=1）を吸収
    return dest
  }

  /// アクティブ workspace の開き直しスタックから直近の 1 件を取り出す（LIFO）。空なら nil＝呼び出し側は無反応。
  func popClosedAgentTab() -> ClosedAgentTab? { current.closedAgentTabs.popLast() }

  /// アクティブ workspace 内でタブを `from` から `to`（挿入先 index・0…count）へ移動する。範囲外・
  /// 実移動なし（同位置）は false。アクティブだった `TerminalTab` の参照を控え、並べ替え後の
  /// index を引き直して `active` を補正する（from/to の前後で場合分けするより堅牢）。ビュー副作用は
  /// 持たない（全タブは mount 済みのまま・可視/非可視も不変）＝呼び出し側が chrome 再投影と保存を担う。
  @discardableResult func moveTab(from: Int, to: Int) -> Bool {
    let tabs = current.tabs
    guard tabs.indices.contains(from), (0...tabs.count).contains(to) else { return false }
    // `to` は挿入前 index 基準。from を抜いた後の実挿入先が from と同じなら実移動なし。
    let dest = to > from ? to - 1 : to
    guard dest != from else { return false }
    let ws = current
    let activeTab = ws.tabs.indices.contains(ws.active) ? ws.tabs[ws.active] : nil
    let moved = ws.tabs.remove(at: from)
    ws.tabs.insert(moved, at: dest)
    if let activeTab, let idx = ws.tabs.firstIndex(where: { $0 === activeTab }) {
      ws.active = idx
    }
    return true
  }

  /// 指定 workspace の末尾へタブを足す（control spawn 用）。背景 workspace のときは active も末尾へ。
  /// アクティブ workspace のときは active を触らない（呼び出し側が select で mount する）。index の
  /// 妥当性は呼び出し側が保証する。
  func appendTab(_ tab: TerminalTab, toWorkspaceAt i: Int) {
    let ws = workspaces[i]
    ws.tabs.append(tab)
    if i != activeWorkspace { ws.active = ws.tabs.count - 1 }
  }

  /// `removeTab` の判定結果。呼び出し側はこれに応じてビュー副作用を実行する。
  enum CloseTabOutcome {
    case notFound
    case emptiedActive
    case reselectActive(Int)
    case backgroundChanged
  }

  /// タブを配列から外し active を補正して分岐を返す。アクティブ workspace が空（0タブ）化したときは
  /// エントリをその場に残したまま `.emptiedActive` を返す（退避せず空でアクティブ維持）。空化時の
  /// `ws.active` は `max(0, min(0, -1)) = 0` に補正され、再アクティブ化で index 0 を選べる状態になる。
  /// 人のジェスチャで閉じたエージェントタブなら、配列から外す前に復元単位と位置を開き直しスタックへ
  /// 積む——cwd/セッションは生きた surface から取るため、ビューが外れる前でなければ正しく取れない。
  func removeTab(_ tab: TerminalTab, origin: TabCloseOrigin) -> CloseTabOutcome {
    guard
      let wsIndex = workspaces.firstIndex(where: { ws in ws.tabs.contains { $0 === tab } })
    else { return .notFound }
    let ws = workspaces[wsIndex]
    guard let idx = ws.tabs.firstIndex(where: { $0 === tab }) else { return .notFound }

    if origin.isHumanGesture {
      let state = tab.tabState()
      if state.agent != nil {
        ws.closedAgentTabs.append(ClosedAgentTab(index: idx, state: state))
        if ws.closedAgentTabs.count > Self.closedAgentTabLimit { ws.closedAgentTabs.removeFirst() }
      }
    }

    ws.tabs.remove(at: idx)
    if idx < ws.active { ws.active -= 1 }
    ws.active = max(0, min(ws.active, ws.tabs.count - 1))  // 0タブ時は 0

    guard wsIndex == activeWorkspace else { return .backgroundChanged }
    guard ws.tabs.isEmpty else { return .reselectActive(ws.active) }
    return .emptiedActive  // アクティブ workspace が空化。退避せずその場で空を維持する。
  }

  /// `index` を除く他 workspace のうち MRU（`lastUsedAt` 最大）の index。他が無ければ nil。
  /// アクティブ workspace の明示削除（`closeWorkspace`）で次のアクティブ先を選ぶ。
  private func mruWorkspaceIndex(excluding index: Int) -> Int? {
    workspaces.indices.filter { $0 != index }.max {
      (workspaces[$0].lastUsedAt ?? .distantPast) < (workspaces[$1].lastUsedAt ?? .distantPast)
    }
  }

  // MARK: - workspace CRUD（domain）

  /// アクティブ workspace を切り替える（同一/範囲外は false）。`switchWorkspace` のドメイン部。
  @discardableResult func setActiveWorkspace(_ index: Int) -> Bool {
    guard workspaces.indices.contains(index), index != activeWorkspace else { return false }
    activeWorkspace = index
    return true
  }

  /// workspace を新規作成して末尾をアクティブにする（タブ起こしは呼び出し側）。`~` は
  /// `setWorkspaceDir` と同じくホーム展開する（CLI の `--dir '~/x'` 等をリテラル格納させない）。
  func createWorkspace(name: String, rootPath: String) {
    workspaces.append(Workspace(name: name, rootPath: (rootPath as NSString).expandingTildeInPath))
    activeWorkspace = workspaces.count - 1
  }

  /// workspace を改名する（前後空白を除去。空・範囲外は false）。
  @discardableResult func renameWorkspace(_ index: Int, to name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard workspaces.indices.contains(index), !trimmed.isEmpty else { return false }
    workspaces[index].name = trimmed
    return true
  }

  /// workspace のディレクトリ設定（rootPath）を変更する。`~` はホーム展開する（空・範囲外は false）。
  @discardableResult func setWorkspaceDir(_ index: Int, to path: String) -> Bool {
    let trimmed = path.trimmingCharacters(in: .whitespaces)
    guard workspaces.indices.contains(index), !trimmed.isEmpty else { return false }
    workspaces[index].rootPath = (trimmed as NSString).expandingTildeInPath
    return true
  }

  /// `closeWorkspace` の判定結果。
  enum CloseWorkspaceOutcome {
    case invalid
    case activeChanged
    case backgroundChanged
  }

  /// workspace を削除して `activeWorkspace` をシフトする。最後の 1 つは残す（`.invalid`）。
  /// 背景 workspace の削除ではアクティブの同一性を保つ（index を詰めるだけ）。アクティブ workspace の
  /// 削除では MRU（`lastUsedAt` 最大の他 workspace）を次のアクティブにする。
  func closeWorkspace(_ index: Int) -> CloseWorkspaceOutcome {
    guard workspaces.indices.contains(index), workspaces.count > 1 else { return .invalid }
    guard index == activeWorkspace else {
      workspaces.remove(at: index)
      if index < activeWorkspace { activeWorkspace -= 1 }
      return .backgroundChanged
    }
    // アクティブ workspace の削除。MRU target のオブジェクト参照を控え、削除後に index を引き直す。
    guard let target = mruWorkspaceIndex(excluding: index) else { return .invalid }
    let targetWS = workspaces[target]
    workspaces.remove(at: index)
    activeWorkspace = workspaces.firstIndex { $0 === targetWS } ?? 0
    return .activeChanged
  }
}
