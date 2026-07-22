import AppKit

/// 制御チャネル（外部 → Orbe）の domain 操作。列挙は internal getter 越しに読み、
/// spawn は wire/select/scheduleSave を使う `controlSpawnTab` へ委譲する。
extension WindowController: ControlTarget {
  func controlListWorkspaces() -> [[String: Any]] {
    workspaces.enumerated().map { i, ws in
      [
        "id": ws.id, "name": ws.name, "rootPath": ws.rootPath,
        "active": i == activeWorkspace, "tabCount": ws.tabs.count, "activated": ws.activated,
        "dormantAgentCount": ws.activated ? 0 : ws.dormantAgentCount(),
      ]
    }
  }

  func controlListPanes() -> [[String: Any]] {
    var out: [[String: Any]] = []
    for (wi, ws) in workspaces.enumerated() {
      for (ti, tc) in ws.tabs.enumerated() {
        for pane in tc.controlAllPanes() {
          out.append([
            "paneId": pane.id, "workspaceId": ws.id, "tabId": tc.id,
            "workspaceName": ws.name,
            "title": pane.paneTitle,
            "cwd": (pane.currentPwd ?? pane.initialCwd).map { $0 as Any } ?? NSNull(),
            "agentState": pane.agentState.map { $0 as Any } ?? NSNull(),
            "agentSessionId": pane.agentSessionId.map { $0 as Any } ?? NSNull(),
            "focused": wi == activeWorkspace && ti == ws.active && tc.focusedPane === pane,
          ])
        }
      }
    }
    return out
  }

  /// 検出済みエージェント CLI を列挙する（制御 API の list_agents）。source は
  /// AgentLauncher が保持する canonical な AgentCatalog の検出結果（新規検出は起こさない）。
  /// 検出未完了なら agents は空でそのまま空配列を返す。
  func controlListAgents() -> [[String: Any]] {
    Self.agentRows(agentLauncher.detectedAgents)
  }

  /// AgentCLI を list_agents の JSON 行（command＋絶対 path）へ写す純関数（検出源に依らず固定）。
  static func agentRows(_ agents: [AgentCLI]) -> [[String: Any]] {
    agents.map { ["command": $0.command, "path": $0.path] }
  }

  func controlResolvePane(_ id: Int) -> SurfaceView? {
    for ws in workspaces {
      for tc in ws.tabs {
        for pane in tc.controlAllPanes() where pane.id == id { return pane }
      }
    }
    return nil
  }

  /// エージェント hook の状態報告を発信元ペインへ適用する。`state=="clear"` で状態を消し、
  /// それ以外は state/command を立て sessionId があれば更新する。didSet が agent_state を
  /// emit し、paneAgentStateChanged がタブ・横断ロールアップを更新する。
  func controlReportAgent(pane: SurfaceView, agent: String, state: String, sessionId: String?) {
    if state == "clear" {
      pane.agentState = nil
      pane.agentSessionId = nil
      pane.agentCommand = nil
    } else {
      pane.agentState = state
      pane.agentCommand = agent
      if let sessionId {
        pane.agentSessionId = sessionId
      }
    }
    pane.controller?.paneAgentStateChanged()
  }

  func controlSpawn(workspaceId: Int?, cwd: String?, command: String?) -> Int? {
    let index =
      workspaceId.flatMap { wid in workspaces.firstIndex { $0.id == wid } } ?? activeWorkspace
    return controlSpawnTab(workspaceIndex: index, cwd: cwd, command: command)
  }

  /// 背景/休眠 workspace を前面化し全タブを mount する（制御 API の activate_workspace）。
  /// 切替実体は `switchWorkspace(to:)` に委譲（既アクティブ no-op・0タブは空表示〔自動起動なし〕・mount・
  /// フォーカス・保存を既存経路が担う）。paneId 群は `controlListPanes` と同じ導出で組む。
  func controlActivateWorkspace(workspaceId: Int) -> (activeWorkspaceId: Int, paneIds: [Int])? {
    guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return nil }
    switchWorkspace(to: index)
    let ws = workspaces[index]
    return (ws.id, ws.tabs.flatMap { $0.controlAllPanes().map(\.id) })
  }

  /// 指定 workspace に新タブを開き、新ペイン ID を返す（制御 API の spawn）。
  /// cwd 省略時は GUI（Cmd+T）と同じフォールバック意味論で確定させる:
  /// 対象 workspace のアクティブペイン cwd → その workspace の rootPath。
  func controlSpawnTab(workspaceIndex: Int, cwd: String?, command: String?) -> Int? {
    guard workspaces.indices.contains(workspaceIndex) else { return nil }
    let initialCwd = cwd ?? store.newSurfaceCwd(inWorkspaceAt: workspaceIndex)
    let tc = wire(TerminalController(initialCwd: initialCwd, initialCommand: command))
    store.appendTab(tc, toWorkspaceAt: workspaceIndex)  // 背景 WS はここで active も末尾へ
    if workspaceIndex == activeWorkspace {
      select(workspaces[workspaceIndex].tabs.count - 1)  // surface を起こす（mount）。背景は keep-alive で遅延。
    }
    scheduleSave()
    return tc.controlAllPanes().first?.id
  }

  // MARK: - ペイン/タブ操作（split・close・focus）

  /// 指定ペインを分割し新ペイン ID を返す（split_pane）。direction は "right"=左右（Cmd+D）・
  /// "down"=上下（Cmd+Shift+D）。所有 TerminalController の split(from:command:) へ委譲する。
  func controlSplitPane(paneId: Int, direction: String, command: String?) -> Result<
    Any, ControlError
  > {
    guard let pane = controlResolvePane(paneId), let tc = pane.controller else {
      return .failure(ControlError(code: -32004, message: "pane not found"))
    }
    let orientation: NSUserInterfaceLayoutOrientation =
      direction == "right" ? .horizontal : .vertical
    // ここへ来る＝ペインは解決済みだが split 自体が失敗（未 mount 等）。"pane not found" は誤誘導。
    guard let newPane = tc.split(orientation, from: pane, command: command) else {
      return .failure(ControlError(code: -32000, message: "split failed"))
    }
    return .success(["paneId": newPane.id])
  }

  /// 指定ペインを閉じる（close_pane）。所有 TerminalController.close へ委譲し、畳み込み・カスケード
  /// （最後の 1 枚ならタブを閉じ、アクティブ WS 最後のタブは0タブ空維持）は既存ロジックに一任する。
  func controlClosePane(paneId: Int) -> Result<Any, ControlError> {
    guard let pane = controlResolvePane(paneId), let tc = pane.controller else {
      return .failure(ControlError(code: -32004, message: "pane not found"))
    }
    tc.close(pane)
    return .success(["ok": true])
  }

  /// 指定ペインへフォーカスする（focus_pane）。list_panes と同じ走査で (wsIndex, tabIndex) を特定し、
  /// 別 WS なら switchWorkspace で activate、その上でタブを選び first responder を移す（既フォーカスでも成功＝冪等）。
  func controlFocusPane(paneId: Int) -> Result<Any, ControlError> {
    for (wi, ws) in workspaces.enumerated() {
      for (ti, tc) in ws.tabs.enumerated() {
        for pane in tc.controlAllPanes() where pane.id == paneId {
          if wi != activeWorkspace { switchWorkspace(to: wi) }
          select(ti)
          window.makeFirstResponder(pane)
          tc.focusedPaneChanged(pane)
          return .success(["ok": true])
        }
      }
    }
    return .failure(ControlError(code: -32004, message: "pane not found"))
  }

  /// 指定タブ（TerminalController.id）を閉じる（close_tab）。id 解決の上で internal 化した closeTab へ
  /// 素直に委譲し、カスケード（ペイン→タブ→アクティブ WS 最後のタブは0タブ空維持）を GUI（Cmd+W）と完全一致させる。
  func controlCloseTab(tabId: Int) -> Result<Any, ControlError> {
    guard let tc = controlResolveTab(tabId) else {
      return .failure(ControlError(code: -32004, message: "tab not found"))
    }
    closeTab(tc)
    return .success(["ok": true])
  }

  /// タブを id で解決する（controlResolvePane の鏡。全 workspace の tabs を tc.id で走査）。
  func controlResolveTab(_ id: Int) -> TerminalController? {
    for ws in workspaces {
      for tc in ws.tabs where tc.id == id { return tc }
    }
    return nil
  }

  // MARK: - config（設定の列挙・設定）

  /// 全設定項目の実効値・由来 scope・型・値域（domain）を列挙する（config CLI）。実効値は global 層に
  /// 対象 workspace 上書き層を重ねて解決する（全設定 WS 可）。default-agent の domain は検出済み一覧を動的に差す。
  /// workspaceId 指定でその WS の上書きを、未指定はアクティブ WS の上書きを重ねる。未知 id は -32004。
  func controlConfigList(workspaceId: Int?) -> Result<Any, ControlError> {
    let override: SettingsLayer?
    if let workspaceId {
      guard let ws = workspaces.first(where: { $0.id == workspaceId }) else {
        return .failure(ControlError(code: -32004, message: "workspace not found"))
      }
      override = ws.settingsOverride
    } else {
      override = current.settingsOverride
    }
    let global = settingsStore.global
    let rows = SettingsRegistry.all.map {
      Self.configRow(
        descriptor: $0, global: global, override: override,
        detectedAgents: agentLauncher.detectedCommands)
    }
    return .success(["settings": rows])
  }

  /// 設定項目 1 件の実効値・scope・type・domain を組む純関数（registry 走査の generic 1 実装）。
  /// scope は「override があれば workspace／global が持てば global／どちらも無ければ default（既定値）」。
  static func configRow(
    descriptor d: SettingDescriptor, global: SettingsLayer, override: SettingsLayer?,
    detectedAgents: [String]
  ) -> [String: Any] {
    let overrideVal = override?.value(d.id)
    let globalVal = global.value(d.id)
    let effective = overrideVal ?? globalVal ?? d.defaultValue()
    let scope = overrideVal != nil ? "workspace" : (globalVal != nil ? "global" : "default")
    return [
      "key": d.key,
      "value": jsonValue(effective),
      "scope": scope,
      "type": d.domain.typeName,
      "domain": domainJSON(d, detectedAgents: detectedAgents),
    ]
  }

  /// `SettingValue?` を JSON 露出値へ（nil＝NSNull）。
  private static func jsonValue(_ v: SettingValue?) -> Any {
    switch v {
    case .int(let n): return n
    case .bool(let b): return b
    case .string(let s): return s
    case .stringMap(let m): return m
    case nil: return NSNull()
    }
  }

  /// descriptor の domain を control の domain JSON へ。enum の値域は defaultAgent だけ検出済み一覧を動的に差す。
  private static func domainJSON(_ d: SettingDescriptor, detectedAgents: [String]) -> [String: Any]
  {
    switch d.domain {
    case .intRange(let range, let step, let unit):
      return [
        "min": range.lowerBound, "max": range.upperBound, "step": step, "unit": unit,
      ]
    case .toggle:
      return ["values": [true, false]]
    case .enumeration(let values):
      return ["values": d.id == .defaultAgent ? detectedAgents : values()]
    case .stringMap:
      let symbols = Dictionary(
        uniqueKeysWithValues: AgentStateIcon.curatedSymbols.map { ($0.key.state, $0.value) })
      return ["symbols": symbols]
    }
  }

  /// 設定 1 項目を global / workspace スコープへ設定しライブ反映する（config CLI）。全設定が同じ 1 経路で、
  /// 値検証は `SettingChange(key:jsonValue:)`（domain 駆動）が担う。value: null は「解除（継承へ）」として受理。
  /// workspace スコープ＋workspaceId 指定でその WS（未指定はアクティブ WS）の上書きへ書く。未知 id は -32004。
  func controlConfigSet(key: String, value: Any, scope: String, workspaceId: Int?) -> Result<
    Any, ControlError
  > {
    guard scope == "global" || scope == "workspace" else {
      return .failure(ControlError(code: -32602, message: "invalid scope: \(scope)"))
    }
    guard let change = SettingChange(key: key, jsonValue: value) else {
      return .failure(ControlError(code: -32602, message: "invalid key or value for \(key)"))
    }
    // workspace スコープで workspaceId 指定時はその WS を対象に（未指定・global はアクティブ WS）。
    var target: Workspace?
    if scope == "workspace", let workspaceId {
      guard let ws = workspaces.first(where: { $0.id == workspaceId }) else {
        return .failure(ControlError(code: -32004, message: "workspace not found"))
      }
      target = ws
    }
    applySetting(change, scope: scope == "workspace" ? .workspace : .global, target: target)
    return .success(["ok": true, "key": key, "value": value, "scope": scope])
  }

  // MARK: - workspace（作成・改名・削除）

  /// workspace を新規作成しアクティブ化する（config CLI `ws new`）。name 空は -32602。
  func controlCreateWorkspace(name: String, rootPath: String?) -> Result<Any, ControlError> {
    guard let id = createWorkspace(name: name, rootPath: rootPath) else {
      return .failure(ControlError(code: -32602, message: "workspace name is empty"))
    }
    let ws = current
    return .success(["workspaceId": id, "name": ws.name, "rootPath": ws.rootPath])
  }

  /// workspace を改名する（`ws rename`）。id 未発見 -32004・name 空 -32602。
  func controlRenameWorkspace(workspaceId: Int, name: String) -> Result<Any, ControlError> {
    guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
      return .failure(ControlError(code: -32004, message: "workspace not found"))
    }
    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
      return .failure(ControlError(code: -32602, message: "workspace name is empty"))
    }
    renameWorkspace(index, to: name)
    return .success(["ok": true])
  }

  /// workspace の rootPath を変更する（`ws dir`）。id 未発見 -32004・rootPath 空 -32602。
  /// 意味論は GUI（パレットのディレクトリ変更）と同一: trim・`~` ホーム展開・実在チェックなし。
  func controlSetWorkspaceRoot(workspaceId: Int, rootPath: String) -> Result<Any, ControlError> {
    guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
      return .failure(ControlError(code: -32004, message: "workspace not found"))
    }
    guard !rootPath.trimmingCharacters(in: .whitespaces).isEmpty else {
      return .failure(ControlError(code: -32602, message: "workspace rootPath is empty"))
    }
    setWorkspaceDir(index, to: rootPath)
    return .success(["ok": true])
  }

  /// workspace を削除する（`ws rm`）。id 未発見 -32004・最後の 1 つは削除不可 -32000。
  func controlRemoveWorkspace(workspaceId: Int) -> Result<Any, ControlError> {
    guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
      return .failure(ControlError(code: -32004, message: "workspace not found"))
    }
    // closeWorkspace は最後の 1 つ（.invalid）を no-op で握るため、CLI へ明示エラーを返すべく事前判定する。
    guard workspaces.count > 1 else {
      return .failure(ControlError(code: -32000, message: "cannot remove last workspace"))
    }
    closeWorkspace(index)
    return .success(["ok": true])
  }
}
