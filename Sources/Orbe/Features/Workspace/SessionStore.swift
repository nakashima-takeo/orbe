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

/// 1 タブと、その居場所の workspace の index。
/// `SessionStore.allTabs()` の走査結果と `restoreDormantTab` の戻り値が共有する。
struct TabRef {
  let workspaceIndex: Int
  let tab: TerminalTab
}

/// ドメイン/セッション状態（`workspaces` と `activeWorkspace`）の唯一の所有者。
/// 配列の CRUD・選択の規則・MRU 退避先選定・workspace の index 演算といった純ドメイン
/// ロジックだけを持ち、ビューの mount/reparent や chrome 投影は WindowController に残す。
///
/// タブ配列の不変条件「同じ `groupKey` のタブは配列上で必ず隣接する」の唯一の保証者。変異点
/// （挿入・cd 再判定・並び替え・セグメント移動・load の正規化）がすべてこれを守り、
/// 「セグメント」はドメイン型ではなく `segments(of:)` が配列から導く連。
/// 選択（`Workspace.selection`）の不変条件の唯一の保証者でもある。
/// Foundation のみに依存する（同モジュール型 `Workspace`/`TerminalTab` の名前参照は
/// フレームワーク import を要さない）。
final class SessionStore {
  private(set) var workspaces: [Workspace]
  private(set) var activeWorkspace: Int
  /// Home（Orbe 自身の窓口になる、消せない workspace）の `persistentId`。一覧の側が 1 つだけを指す。
  /// 指す先が一覧に無ければ Home は無い。それ以外の workspace を「通常の workspace」と呼ぶ。
  private(set) var homeWorkspaceId: UUID?
  var current: Workspace { workspaces[activeWorkspace] }

  init(workspaces: [Workspace] = [], activeWorkspace: Int = 0) {
    self.workspaces = workspaces
    self.activeWorkspace = activeWorkspace
  }

  /// 復元/初期化で組み立て済みの配列一式を差し替える（WindowController.init が wire 後に渡す）。
  /// 隣接不変条件と選択の不変条件の入口——各 workspace のタブを `grouped` で正規化し、選択を `settle` でそろえる。
  /// 渡した配列をそのまま入れる（Home を足すのは `ensureHome`）。
  func load(workspaces: [Workspace], activeWorkspace: Int, homeWorkspaceId: UUID? = nil) {
    self.workspaces = workspaces
    self.activeWorkspace = activeWorkspace
    self.homeWorkspaceId = homeWorkspaceId
    for ws in workspaces {
      ws.tabs = Self.grouped(ws.tabs)
      settle(ws)
    }
  }

  // MARK: - ボードと選択の不変条件

  /// ボードを持つか。今は Home だけが持つ。
  func hasBoard(_ workspace: Workspace) -> Bool {
    homeWorkspaceId != nil && workspace.persistentId == homeWorkspaceId
  }

  /// 選択が不変条件を満たしていなければ、休む先（ボード → 先頭のタブ → 空）へ寄せる。
  private func settle(_ ws: Workspace) {
    if isValid(ws.selection, in: ws) { return }
    ws.selection = restingSelection(of: ws)
  }

  private func isValid(_ selection: Workspace.Selection, in ws: Workspace) -> Bool {
    switch selection {
    case .tab(let tab): return ws.tabs.contains { $0 === tab }
    case .board: return hasBoard(ws)
    case .empty: return ws.tabs.isEmpty && !hasBoard(ws)
    }
  }

  private func restingSelection(of ws: Workspace) -> Workspace.Selection {
    if hasBoard(ws) { return .board }
    return ws.tabs.first.map { .tab($0) } ?? .empty
  }

  // MARK: - Home

  /// 「Home がちょうど 1 つあり、root が `rootPath`」へそろえる（起動時に復元の後で 1 回）。
  /// 指している workspace があれば root を上書きし、無ければ「Home」を末尾に足して指す（選択はボード）。前面の
  /// workspace は動かさず、タブも作らない。root は state フォルダから導く値なので、保存されていた root は使わない。
  func ensureHome(rootPath: String) {
    if let i = homeIndex {
      workspaces[i].rootPath = rootPath
      return
    }
    let ws = Workspace(name: "Home", rootPath: rootPath)
    workspaces.append(ws)
    homeWorkspaceId = ws.persistentId
    settle(ws)
  }

  /// Home の位置。無ければ nil。
  var homeIndex: Int? {
    guard let homeWorkspaceId else { return nil }
    return workspaces.firstIndex { $0.persistentId == homeWorkspaceId }
  }

  func isHome(_ index: Int) -> Bool { index == homeIndex }

  /// 起源（パレットで Home の次に固定する workspace）＝配列で最初の通常 workspace。
  var originWorkspaceIndex: Int? { workspaces.indices.first { !isHome($0) } }

  /// workspace の削除を妨げる理由。
  enum RemovalBlocker {
    case home
    case lastRegularWorkspace
  }

  /// 指定 workspace を消せない理由。消せるなら nil。workspace index の妥当性は呼び出し側が保証する。
  /// 通常の workspace を 1 つは残す——Home だけになると、新しく起こすタブが Home の
  /// root（リポジトリに属さない場所）で起きる。
  func removalBlocker(_ index: Int) -> RemovalBlocker? {
    if isHome(index) { return .home }
    let regularCount = workspaces.count - (homeIndex == nil ? 0 : 1)
    return regularCount <= 1 ? .lastRegularWorkspace : nil
  }

  /// ディレクトリ（rootPath）を変えられるか。Home の root は state フォルダから導く値なので変えない。
  func canChangeDir(_ index: Int) -> Bool { !isHome(index) }

  // MARK: - 純ドメイン読み

  /// 指定 workspace の選んでいるタブの実効 cwd（`TerminalTab.cwd`）。ボード・空は nil。
  /// workspace index の妥当性は呼び出し側が保証する。
  private func tabCwd(inWorkspaceAt i: Int) -> String? {
    workspaces[i].selectedTab?.cwd
  }

  /// アクティブ workspace の選んでいるタブの実効 cwd。ボード・空は nil。
  func activeTabCwd() -> String? { tabCwd(inWorkspaceAt: activeWorkspace) }

  /// 新しい workspace の root の既定——まだどの workspace にも属していない場所。選んでいるタブの cwd、
  /// ボード・空ならホーム。そこで現 workspace の rootPath へ落とさないのは、無関係な別 workspace の root が
  /// 新 workspace の root として黙って提案されるため（workspace 内で開くタブの場所を決める
  /// `newTabCwd(inWorkspaceAt:)` とはここが違う）。
  func defaultNewWorkspaceRoot() -> String {
    activeTabCwd() ?? FileManager.default.homeDirectoryForCurrentUser.path
  }

  /// 全 workspace × 全タブ（**休眠 workspace も含む**）。
  /// 休眠タブは `currentPwd` を持たないが `initialCwd`（復元値）は持つので、cwd の話には必ず含める。
  func allTabs() -> [TabRef] {
    workspaces.enumerated().flatMap { wi, ws in
      ws.tabs.map { TabRef(workspaceIndex: wi, tab: $0) }
    }
  }

  /// 今 Orbe に居る同一性（全 workspace・live / 休眠を問わない）。`list_tabs` の `agentSessionId` と
  /// 同じ読み口なので、CLI 側の「戻っていない」の導出と一致する。
  var presentSessionIds: Set<String> {
    Set(allTabs().compactMap { $0.tab.agentSlot.session?.sessionId })
  }

  /// 指定 workspace での新規タブ起動の初期 cwd。GUI・エージェント起動・制御 API は `openTab` 越しに
  /// ここを通り、worktree パレットもリポジトリを探す基点として読む（worktree パレットは workspace 内に新タブを開く面
  /// なので、新タブの開始地点を基点にする）。
  /// 当該 workspace の選んでいるタブの cwd を継ぎ、選んでいるタブが無い（ボード・空）ならその workspace の rootPath
  /// へ落とす——開くタブはその workspace のものだから（`defaultNewWorkspaceRoot()` とはここが違う）。
  /// nil を surface へ渡すと ghostty がホームへ解決してしまうため、ここで必ず確定させる。
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

  /// アクティブ workspace の選択のドメイン記録。不変条件に反する選択は拒み（false）、受けたら選択を記録する。
  /// タブかボードを前面に出すのは workspace の利用なので MRU を進める。空は何も前面に出さないので進めない（空の
  /// workspace への切替は、切替そのものを利用として呼び出し側が記録する）。
  /// ビュー除去/mount/focus/chrome は呼び出し側（WindowController.select）が担う。
  @discardableResult func recordSelection(_ selection: Workspace.Selection) -> Bool {
    let ws = current
    guard isValid(selection, in: ws) else { return false }
    if selection != .empty { recordWorkspaceUse(ws) }
    ws.selection = selection
    return true
  }

  /// 次の選択。「ボード（持つなら先頭）＋タブ列」を環として 1 つ進める。空なら nil。
  func nextSelection() -> Workspace.Selection? { cycledSelection(by: 1) }

  /// 前の選択（`nextSelection` の逆回り）。
  func prevSelection() -> Workspace.Selection? { cycledSelection(by: -1) }

  private func cycledSelection(by step: Int) -> Workspace.Selection? {
    let ws = current
    let ring = (hasBoard(ws) ? [Workspace.Selection.board] : []) + ws.tabs.map { .tab($0) }
    guard let i = ring.firstIndex(of: ws.selection) else { return nil }
    return ring[(i + step + ring.count) % ring.count]
  }

  // MARK: - タブ CRUD（domain）

  /// 新規タブを選んで足す。指定 workspace の同キー連の右端（無ければ末尾）へ挿し、実挿入 index を返す。
  /// アクティブ workspace では選択を触らない（呼び出し側が直後に select で mount する）。背景 workspace では選択を
  /// 挿したタブへ。workspace index の妥当性は呼び出し側が保証する。
  @discardableResult func insertTab(_ tab: TerminalTab, intoWorkspaceAt i: Int) -> Int {
    let dest = insert(tab, intoWorkspaceAt: i)
    if i != activeWorkspace { workspaces[i].selection = .tab(tab) }
    return dest
  }

  /// 選ばずに足すタブ（復元した休眠チケット・選ばずに起こすタブ）を、指定 workspace の同キー連の右端（無ければ
  /// 末尾）へ挿し、実挿入 index を返す。選択は動かさない——ただし何も選べていなかった（空の）workspace では、
  /// 選べるものがこのタブだけなのでそれを選ぶ。workspace index の妥当性は呼び出し側が保証する。
  func insertTabUnselected(_ tab: TerminalTab, intoWorkspaceAt i: Int) -> Int {
    let dest = insert(tab, intoWorkspaceAt: i)
    if workspaces[i].selection == .empty { workspaces[i].selection = .tab(tab) }
    return dest
  }

  /// 挿入の実体。同キー連の右端へ挿す。選択は参照なので補正しない。
  private func insert(_ tab: TerminalTab, intoWorkspaceAt i: Int) -> Int {
    let ws = workspaces[i]
    let dest = Self.insertionIndex(forKey: tab.groupKey, in: ws.tabs)
    ws.tabs.insert(tab, at: dest)
    return dest
  }

  /// アクティブ workspace 内でタブを `from` から `to`（挿入先 index・0…count・挿入前基準）へ移動する。
  /// 挿入先は from の連の中（連の右端への挿入 = upperBound を含む）に限り、連の外・範囲外・
  /// 実移動なし（同位置）は false。選択は参照なので補正しない。ビュー副作用は
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
    let moved = ws.tabs.remove(at: from)
    ws.tabs.insert(moved, at: dest)
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
    /// アクティブ workspace のタブが外れた（選択が動いたかに依らず、今の選択を描き直す）。
    case activeWorkspaceChanged
    case backgroundChanged
  }

  /// タブを配列から外して分岐を返す。選択は閉じたタブを選んでいたときだけ動く——右隣（末尾なら左隣）へ、
  /// ただし 2 枚以上の連の右端だったときは同じ連の左隣へ（フォーカスは連の中に留める）。タブが 0 になれば、ボードを
  /// 持つならボード、持たなければ空（workspace は退避せずその場に残す）。
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
    if ws.selectedTab === tab {
      let next =
        idx == r.upperBound - 1 && r.lowerBound < idx ? idx - 1 : min(idx, ws.tabs.count - 1)
      ws.selection = ws.tabs.indices.contains(next) ? .tab(ws.tabs[next]) : restingSelection(of: ws)
    }
    return wsIndex == activeWorkspace ? .activeWorkspaceChanged : .backgroundChanged
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

  /// workspace のディレクトリ設定（rootPath）を変更する。`~` はホーム展開する（空・範囲外・
  /// `canChangeDir` が偽は false）。
  @discardableResult func setWorkspaceDir(_ index: Int, to path: String) -> Bool {
    let trimmed = path.trimmingCharacters(in: .whitespaces)
    guard workspaces.indices.contains(index), canChangeDir(index), !trimmed.isEmpty else {
      return false
    }
    workspaces[index].rootPath = (trimmed as NSString).expandingTildeInPath
    return true
  }

  /// `closeWorkspace` の判定結果。
  enum CloseWorkspaceOutcome {
    case invalid
    case activeChanged
    case backgroundChanged
  }

  /// workspace を削除して `activeWorkspace` をシフトする。`removalBlocker` があれば消さない（`.invalid`）。
  /// 背景 workspace の削除ではアクティブの同一性を保つ（index を詰めるだけ）。アクティブ workspace の
  /// 削除では MRU（`lastUsedAt` 最大の他 workspace）を次のアクティブにする。
  /// 配下のタブには外れる前に `origin`（呼び手が名乗る発火源）を配る（`.invalid` では何も告げない）。
  func closeWorkspace(_ index: Int, origin: TabCloseOrigin) -> CloseWorkspaceOutcome {
    guard workspaces.indices.contains(index), removalBlocker(index) == nil else { return .invalid }
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
