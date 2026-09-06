import Foundation
import OrbeSessionLog

/// タブが store から外れる発火源。閉鎖経路（surface・libghostty ランタイム・制御 API）から
/// `TerminalTab.close` → `onClose` → `WindowController.closeTab` → `SessionStore.removeTab`
/// まで素通しで届き、workspace 削除でも配下タブへ同じ口で配られる。同一性を持ったまま外れたタブは
/// これを「同一性の終わり方」としてセッションログへ写す。
/// デフォルト値を持たせない＝全呼び出し元が発火源を明示することをコンパイラが強制する。
enum TabCloseOrigin {
  /// 人のジェスチャ（タブ行の中クリック・⌘W・WorkspacePalette の削除）。
  case gesture
  /// シェル exit・エージェント終了（libghostty の close_surface_cb）。
  case process
  /// 制御 API（close_tab・remove_workspace）。
  case controlAPI

  /// セッションログの終わり方への写し。網羅 switch（default 無し）＝閉鎖経路が増えたとき
  /// 分類漏れをコンパイルエラーで検出する。
  var sessionLogOrigin: SessionEvent.CloseOrigin {
    switch self {
    case .gesture: return .gesture
    case .process: return .process
    case .controlAPI: return .controlAPI
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

/// ドメイン/セッション状態（`workspaces` と `activeWorkspace`）の唯一の所有者。
/// 配列の CRUD・active index 補正・MRU 退避先選定・workspace の index 演算といった純ドメイン
/// ロジックだけを持ち、ビューの mount/reparent や chrome 投影は WindowController に残す。
///
/// タブ配列の不変条件「同じ `groupKey` のタブは配列上で必ず隣接する」の唯一の保証者。変異点
/// （挿入・cd 再判定・並び替え・セグメント移動・load の正規化）がすべてこれを守り、
/// 「セグメント」はドメイン型ではなく `segments(of:)` が配列から導く連。
/// Foundation のみに依存する（同モジュール型 `Workspace`/`TerminalTab` の名前参照は
/// フレームワーク import を要さない）。
final class SessionStore {
  private(set) var workspaces: [Workspace]
  private(set) var activeWorkspace: Int
  var current: Workspace { workspaces[activeWorkspace] }

  init(workspaces: [Workspace] = [], activeWorkspace: Int = 0) {
    self.workspaces = workspaces
    self.activeWorkspace = activeWorkspace
  }

  /// 復元/初期化で組み立て済みの配列一式を差し替える（WindowController.init が wire 後に渡す）。
  /// 隣接不変条件の入口——各 workspace のタブを `grouped` で正規化し、active は同一性で引き直す。
  func load(workspaces: [Workspace], activeWorkspace: Int) {
    for ws in workspaces {
      let activeTab = ws.tabs.indices.contains(ws.active) ? ws.tabs[ws.active] : nil
      ws.tabs = Self.grouped(ws.tabs)
      if let activeTab, let idx = ws.tabs.firstIndex(where: { $0 === activeTab }) {
        ws.active = idx
      }
    }
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

  /// 今 Orbe に居る同一性（全 workspace・live / 休眠を問わない）。`list_tabs` の `agentSessionId` と
  /// 同じ読み口なので、CLI 側の「戻っていない」の導出と一致する。
  var presentSessionIds: Set<String> {
    Set(allTabs().compactMap { $0.tab.agentSlot.session?.sessionId })
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

  /// 新規タブ。指定 workspace の同キー連の右端（無ければ末尾）へ挿し、実挿入 index を返す。
  /// アクティブ workspace では active を触らず同じタブを指し続けさせる（呼び出し側が直後に select で
  /// mount する）。背景 workspace では active を挿したタブへ。workspace index の妥当性は呼び出し側が保証する。
  func insertTab(_ tab: TerminalTab, intoWorkspaceAt i: Int) -> Int {
    let ws = workspaces[i]
    let dest = insertKeepingSelection(tab, intoWorkspaceAt: i)
    if i != activeWorkspace { ws.active = dest }
    return dest
  }

  /// 復元した休眠チケットを、指定 workspace の同キー連の右端（無ければ末尾）へ挿し、実挿入 index を返す。
  /// `active` は挿す前と同じタブを指し続ける——復元は「見せる先を変えない」ので、背景 workspace で
  /// active を挿したタブへ動かす `insertTab` を継がない（0 タブだった workspace は `active == 0` のままで
  /// 新タブがそれになる）。workspace index の妥当性は呼び出し側が保証する。
  func insertRestoredTab(_ tab: TerminalTab, intoWorkspaceAt i: Int) -> Int {
    insertKeepingSelection(tab, intoWorkspaceAt: i)
  }

  /// 挿入の実体。同キー連の右端へ挿し、挿入位置が現 active 以前なら active を 1 つ繰り下げて
  /// 挿入前と同じタブを指し続けさせる（0タブへの挿入は count−1 へのクランプで吸収）。
  private func insertKeepingSelection(_ tab: TerminalTab, intoWorkspaceAt i: Int) -> Int {
    let ws = workspaces[i]
    let dest = Self.insertionIndex(forKey: tab.groupKey, in: ws.tabs)
    ws.tabs.insert(tab, at: dest)
    if dest <= ws.active { ws.active += 1 }
    ws.active = min(ws.active, ws.tabs.count - 1)
    return dest
  }

  /// アクティブ workspace 内でタブを `from` から `to`（挿入先 index・0…count・挿入前基準）へ移動する。
  /// 挿入先は from の連の中（連の右端への挿入 = upperBound を含む）に限り、連の外・範囲外・
  /// 実移動なし（同位置）は false。アクティブだった `TerminalTab` の参照を控え、並べ替え後の
  /// index を引き直して `active` を補正する（from/to の前後で場合分けするより堅牢）。ビュー副作用は
  /// 持たない（全タブは mount 済みのまま・可視/非可視も不変）＝呼び出し側が chrome 再投影と保存を担う。
  @discardableResult func moveTab(from: Int, to: Int) -> Bool {
    let tabs = current.tabs
    guard tabs.indices.contains(from), (0...tabs.count).contains(to) else { return false }
    let r = Self.segment(containing: from, in: tabs)
    guard (r.lowerBound...r.upperBound).contains(to) else { return false }
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

  /// タブが store から外れることを、配列から外す**前**にタブへ告げる唯一の口。同一性が残っていれば
  /// タブがその終わりをログへ写す——記録側が所属 workspace をタブから引くため、外した後では引けず、
  /// イベントが無言で落ちる。
  private func detach(_ tab: TerminalTab, origin: TabCloseOrigin) {
    tab.recordDetached(origin: origin)
  }

  /// `removeTab` の判定結果。呼び出し側はこれに応じてビュー副作用を実行する。
  enum CloseTabOutcome {
    case notFound
    case emptiedActive
    case reselectActive(Int)
    case backgroundChanged
  }

  /// タブを配列から外し active を補正して分岐を返す。閉じたタブがアクティブなら右隣が新 active になる
  /// （index 据え置き・末尾は左へクランプ）が、2 枚以上の連の右端だったときだけ同じ連の左隣を優先する
  /// （フォーカスは連の中に留める）。アクティブ workspace が空（0タブ）化したときは
  /// エントリをその場に残したまま `.emptiedActive` を返す（退避せず空でアクティブ維持）。空化時の
  /// `ws.active` は `max(0, min(0, -1)) = 0` に補正され、再アクティブ化で index 0 を選べる状態になる。
  /// 配列から外す前に同一性の終わりをタブへ告げる（`detach`）。
  func removeTab(_ tab: TerminalTab, origin: TabCloseOrigin) -> CloseTabOutcome {
    guard
      let wsIndex = workspaces.firstIndex(where: { ws in ws.tabs.contains { $0 === tab } })
    else { return .notFound }
    let ws = workspaces[wsIndex]
    guard let idx = ws.tabs.firstIndex(where: { $0 === tab }) else { return .notFound }

    detach(tab, origin: origin)
    let r = Self.segment(containing: idx, in: ws.tabs)
    ws.tabs.remove(at: idx)
    if idx < ws.active {
      ws.active -= 1
    } else if idx == ws.active, idx == r.upperBound - 1, r.lowerBound < idx {
      ws.active = idx - 1  // 連の右端を閉じた＝左隣は同じ連
    }
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
    activeWorkspace = appendWorkspace(name: name, rootPath: rootPath)
  }

  /// workspace を末尾に足し、その index を返す。アクティブ化しない（`restore_sessions` が復元先を
  /// 作り直すときの形——「作って開く」意図の `createWorkspace` と違い、見せる先を変えない）。
  func appendWorkspace(name: String, rootPath: String) -> Int {
    workspaces.append(Workspace(name: name, rootPath: (rootPath as NSString).expandingTildeInPath))
    return workspaces.count - 1
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
  /// 配下のタブには外れる前に `origin`（呼び手が名乗る発火源）を配る（`.invalid` では何も告げない）。
  func closeWorkspace(_ index: Int, origin: TabCloseOrigin) -> CloseWorkspaceOutcome {
    guard workspaces.indices.contains(index), workspaces.count > 1 else { return .invalid }
    guard index == activeWorkspace else {
      workspaces[index].tabs.forEach { detach($0, origin: origin) }
      workspaces.remove(at: index)
      if index < activeWorkspace { activeWorkspace -= 1 }
      return .backgroundChanged
    }
    // アクティブ workspace の削除。MRU target のオブジェクト参照を控え、削除後に index を引き直す。
    guard let target = mruWorkspaceIndex(excluding: index) else { return .invalid }
    let targetWS = workspaces[target]
    workspaces[index].tabs.forEach { detach($0, origin: origin) }
    workspaces.remove(at: index)
    activeWorkspace = workspaces.firstIndex { $0 === targetWS } ?? 0
    return .activeChanged
  }
}
