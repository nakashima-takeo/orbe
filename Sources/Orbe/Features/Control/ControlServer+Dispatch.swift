import Foundation
import OrbeSessionLog

/// タブ宛て・config・workspace CRUD・セッション復元の動詞と、エージェントの起動・hook 報告の受け。引数の検証（-32602）は
/// ここのハンドラが行い、ドメインの解決（-32004 等）は target 側が返す。
extension ControlServer {
  private static let tabNotFound = ControlError(code: -32004, message: "tab not found")

  // MARK: - サーバーがタブを解決してから触る動詞（未解決のタブは -32004）

  /// `scrollback` は省略で見えている範囲だけ。
  static func getTabText(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    let tabId = try p.optionalInt("tabId")
    let scrollback = try p.optionalBool("scrollback") ?? false
    guard let tab = tabId.flatMap(target.controlResolveTab) else { return .failure(tabNotFound) }
    return .success(["text": tab.surface.controlReadText(scrollback: scrollback) ?? ""])
  }

  static func sendText(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    let tabId = try p.optionalInt("tabId")
    let text = try p.optionalString("text")
    guard let tab = tabId.flatMap(target.controlResolveTab) else { return .failure(tabNotFound) }
    guard let text else { throw p.missing("text") }
    tab.surface.controlSendText(text)
    return .success(["ok": true])
  }

  static func sendKey(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    let tabId = try p.optionalInt("tabId")
    let spec = try p.optionalString("key")
    guard let tab = tabId.flatMap(target.controlResolveTab) else { return .failure(tabNotFound) }
    guard let key = spec.flatMap(ControlKey.parse) else { throw p.invalid("key") }
    tab.surface.controlSendKey(key)
    return .success(["ok": true])
  }

  // MARK: - タブ操作（タブの解決は target が持つ）

  static func focusTab(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    target.controlFocusTab(tabId: try p.int("tabId"))
  }

  static func closeTab(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    target.controlCloseTab(tabId: try p.int("tabId"))
  }

  static func openFile(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    let tabId = try p.int("tabId")
    guard let path = try p.optionalString("path"), !path.isEmpty else { throw p.missing("path") }
    return target.controlOpenFile(tabId: tabId, path: path)
  }

  // MARK: - hook の報告

  /// `report_agent`。報告者は接続の向こうのプロセスなので、接続が取った報告者のグループを報告に添えて main で適用する
  /// （会話へ貼ってよいかは、報告者が端末の前面のグループに属するかで決まる）。未解決のタブは -32004。
  func reportAgent(id: Any?, params p: ControlParams, conn: Connection) {
    let tabId: Int?
    let report: AgentHookReport?
    do throws(ControlError) {
      tabId = try p.optionalInt("tabId")
      report = try Self.hookReport(p)
    } catch {
      return conn.respond(id: id, result: .failure(error))
    }
    let reporterGroup = conn.peerGroup
    DispatchQueue.main.async {
      let result: Result<Any, ControlError> = self.onWindow { target in
        guard let tab = tabId.flatMap(target.controlResolveTab) else {
          return .failure(Self.tabNotFound)
        }
        guard var report else {
          return .failure(ControlError(code: -32602, message: "missing agent/state"))
        }
        report.reporterGroup = reporterGroup
        target.controlReportAgent(tab: tab, report: report)
        return .success(["ok": true])
      }
      self.queue.async { conn.respond(id: id, result: result) }
    }
  }

  /// `report_agent` の引数を hook 1 発の報告へ写す。`agent` / `state` が無ければ nil（-32602）。
  /// 省ける `sessionId` / `message`（＋`messageSource`）/ `reason` は名前どおり運ぶ。
  private static func hookReport(_ p: ControlParams) throws(ControlError) -> AgentHookReport? {
    let agent = try p.optionalString("agent")
    let state = try p.optionalString("state")
    let sessionId = try p.optionalString("sessionId")
    let message = try p.optionalString("message")
    let source = try p.optionalString("messageSource")
    let reason = try p.optionalString("reason")
    guard let agent, let state else { return nil }
    return AgentHookReport(
      agent: agent, state: state, sessionId: sessionId,
      message: message.map { AgentMessage(text: $0, source: source) }, reason: reason)
  }

  // MARK: - エージェントの起動

  /// `spawn_agent`。command は省略で対象 workspace の実効 default-agent（target が解く）。workspace / agent の解決は target が返す。
  func spawnAgent(id: Any?, params p: ControlParams, conn: Connection) {
    let timeoutMs: Int
    let command: String?
    let workspaceId: UUID?
    let cwd: String?
    do throws(ControlError) {
      command = try p.optionalString("command")
      workspaceId = try p.optionalWorkspaceId()
      cwd = try p.optionalString("cwd")
      timeoutMs = try WaitTimeout.parse(p, default: WaitTimeout.launchDefaultMs)
    } catch {
      return conn.respond(id: id, result: .failure(error))
    }
    launchAgent(id: id, conn: conn, timeoutMs: timeoutMs) {
      $0.controlSpawnAgent(command: command, workspaceId: workspaceId, cwd: cwd)
    }
  }

  /// `resume_agent`。sessionId の文字集合検証は target（`controlResumeAgent` の `AgentCatalog.isSafeSessionId`）が持つ。
  func resumeAgent(id: Any?, params p: ControlParams, conn: Connection) {
    let timeoutMs: Int
    let command: String
    let sessionId: String
    let workspaceId: UUID?
    let cwd: String?
    do throws(ControlError) {
      command = try p.string("command")
      sessionId = try p.string("sessionId")
      workspaceId = try p.optionalWorkspaceId()
      cwd = try p.optionalString("cwd")
      timeoutMs = try WaitTimeout.parse(p, default: WaitTimeout.launchDefaultMs)
    } catch {
      return conn.respond(id: id, result: .failure(error))
    }
    launchAgent(id: id, conn: conn, timeoutMs: timeoutMs) {
      $0.controlResumeAgent(
        command: command, sessionId: sessionId, workspaceId: workspaceId, cwd: cwd)
    }
  }

  // MARK: - セッション復元・config・workspace CRUD

  /// `restore_sessions`。引数の検証（型・件数・安全文字集合）はここで、ログの照合と復元は target が行う。
  static func restoreSessions(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    let ids = try p.strings("sessionIds")
    guard !ids.isEmpty, ids.count <= SessionLogLimits.restoreMaxIds,
      ids.allSatisfy(AgentCatalog.isSafeSessionId)
    else { throw p.invalid("sessionIds") }
    return target.controlRestoreSessions(sessionIds: ids)
  }

  static func configList(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    target.controlConfigList(workspaceId: try p.optionalWorkspaceId())
  }

  /// `value` は型を問わない（`null` は解除）。値の検証は設定のレジストリが持つ。
  static func configSet(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    let key = try p.string("key")
    let value = try p.value("value")
    let scope = try p.string("scope")
    return target.controlConfigSet(
      key: key, value: value, scope: scope, workspaceId: try p.optionalWorkspaceId())
  }

  static func createWorkspace(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    let name = try p.string("name")
    return target.controlCreateWorkspace(name: name, rootPath: try p.optionalString("rootPath"))
  }

  static func renameWorkspace(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    let workspaceId = try p.workspaceId()
    return target.controlRenameWorkspace(workspaceId: workspaceId, name: try p.string("name"))
  }

  static func setWorkspaceRoot(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    let workspaceId = try p.workspaceId()
    return target.controlSetWorkspaceRoot(
      workspaceId: workspaceId, rootPath: try p.string("rootPath"))
  }

  static func removeWorkspace(_ target: ControlTarget, _ p: ControlParams) throws(ControlError)
    -> Result<Any, ControlError>
  {
    target.controlRemoveWorkspace(workspaceId: try p.workspaceId())
  }
}
