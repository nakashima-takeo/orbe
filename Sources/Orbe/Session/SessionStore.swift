import Foundation

/// ドメイン/セッション状態（`workspaces` と `activeWorkspace`）の唯一の所有者。
/// 配列の CRUD・active index 補正・MRU 退避先選定・workspace の index 演算といった純ドメイン
/// ロジックだけを持ち、ビューの mount/reparent や chrome 投影は WindowController に残す。
/// Foundation のみに依存する（同モジュール型 `Workspace`/`TerminalController` の名前参照は
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
  func load(workspaces: [Workspace], activeWorkspace: Int) {
    self.workspaces = workspaces
    self.activeWorkspace = activeWorkspace
  }

  // MARK: - 純ドメイン読み

  /// 指定 workspace のアクティブペインの実効 cwd（OSC 7 報告前は起動時 cwd＝復元値）。
  /// snapshot() と同じ `currentPwd ?? initialCwd` の契約。タブ index ガードつき
  /// （workspace index の妥当性は呼び出し側が保証する）。
  private func paneCwd(inWorkspaceAt i: Int) -> String? {
    let ws = workspaces[i]
    guard ws.tabs.indices.contains(ws.active) else { return nil }
    let pane = ws.tabs[ws.active].focusedPane
    return pane?.currentPwd ?? pane?.initialCwd
  }

  /// アクティブペインの実効 cwd。
  func activePaneCwd() -> String? { paneCwd(inWorkspaceAt: activeWorkspace) }

  /// 新規タブ/エージェント起動の初期 cwd（アクティブ workspace）。
  func newSurfaceCwd() -> String { newSurfaceCwd(inWorkspaceAt: activeWorkspace) }

  /// 指定 workspace での新規タブ起動の初期 cwd（active ラッパ経由で GUI・エージェント起動も通る）。
  /// 当該 workspace のアクティブペインの cwd を継ぎ、ペイン不在（0タブ）はその workspace の rootPath
  /// へ落とす。nil を surface へ渡すと ghostty がホームへ解決してしまうため、ここで必ず確定させる。
  /// workspace index の妥当性は呼び出し側が保証する。
  func newSurfaceCwd(inWorkspaceAt i: Int) -> String {
    paneCwd(inWorkspaceAt: i) ?? workspaces[i].rootPath
  }

  /// アクティブタブが所有する EditorPane UI 状態（EditorPaneController へ注入する単一真実）。
  /// タブ不在は nil。
  func activeEditorUI() -> EditorPaneUIState? {
    guard current.tabs.indices.contains(current.active) else { return nil }
    return current.tabs[current.active].editorUI
  }

  // MARK: - select のブックキーピング（ビューは触らない）

  /// タブ選択のドメイン記録。index ガード → `activated`→`lastUsedAt`→`active` の順で立て、成否を返す。
  /// ビュー除去/mount/focus/chrome は呼び出し側（WindowController.select）が担う。
  @discardableResult func recordSelection(_ index: Int) -> Bool {
    guard current.tabs.indices.contains(index) else { return false }
    let ws = current
    ws.activated = true
    ws.lastUsedAt = Date()  // アクティブ化＝MRU 上の「使った」時刻
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

  /// アクティブ workspace の末尾へタブを足す（active は変えない＝select は呼び出し側）。
  func appendTabToActive(_ tc: TerminalController) {
    current.tabs.append(tc)
  }

  /// アクティブ workspace 内でタブを `from` から `to`（挿入先 index・0…count）へ移動する。範囲外・
  /// 実移動なし（同位置）は false。アクティブだった `TerminalController` の参照を控え、並べ替え後の
  /// index を引き直して `active` を補正する（from/to の前後で場合分けするより堅牢）。ビュー副作用は
  /// 持たない（全タブは mount 済みのまま・可視/非可視も不変）＝呼び出し側が chrome 再投影と保存を担う。
  @discardableResult func moveTab(from: Int, to: Int) -> Bool {
    let tabs = current.tabs
    guard tabs.indices.contains(from), (0...tabs.count).contains(to) else { return false }
    // `to` は挿入前 index 基準。from を抜いた後の実挿入先が from と同じなら実移動なし。
    let dest = to > from ? to - 1 : to
    guard dest != from else { return false }
    let ws = current
    let activeTC = ws.tabs.indices.contains(ws.active) ? ws.tabs[ws.active] : nil
    let moved = ws.tabs.remove(at: from)
    ws.tabs.insert(moved, at: dest)
    if let activeTC, let idx = ws.tabs.firstIndex(where: { $0 === activeTC }) {
      ws.active = idx
    }
    return true
  }

  /// 指定 workspace の末尾へタブを足す（control spawn 用）。背景 workspace のときは active も末尾へ。
  /// アクティブ workspace のときは active を触らない（呼び出し側が select で mount する）。index の
  /// 妥当性は呼び出し側が保証する。
  func appendTab(_ tc: TerminalController, toWorkspaceAt i: Int) {
    let ws = workspaces[i]
    ws.tabs.append(tc)
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
  func removeTab(_ tc: TerminalController) -> CloseTabOutcome {
    guard
      let wsIndex = workspaces.firstIndex(where: { ws in ws.tabs.contains { $0 === tc } })
    else { return .notFound }
    let ws = workspaces[wsIndex]
    guard let idx = ws.tabs.firstIndex(where: { $0 === tc }) else { return .notFound }

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
