import Foundation

/// 制御チャネルの「拡張」メソッド dispatch（ペイン/タブ操作・config・workspace CRUD）。
/// 中核の動詞（list/get/send/spawn 等）は `runWindowed` の switch が持ち、ここは fall-through で
/// 引き受ける。param 検証（-32602）はここで行い、ドメイン解決（-32004 等）は target 側が返す。
extension ControlServer {
  /// ペイン/タブ操作（split_pane / close_pane / focus_pane / close_tab）を dispatch する。
  /// 非該当は nil で次のハンドラ（config / workspace）へ落とす。
  func runPaneTab(method: String, params: [String: Any], target: ControlTarget)
    -> Result<Any, ControlError>?
  {
    switch method {
    case "split_pane":
      guard let pid = params["paneId"] as? Int else {
        return .failure(ControlError(code: -32602, message: "missing paneId"))
      }
      guard let direction = params["direction"] as? String,
        direction == "right" || direction == "down"
      else {
        return .failure(ControlError(code: -32602, message: "invalid direction"))
      }
      return target.controlSplitPane(
        paneId: pid, direction: direction, command: params["command"] as? String)
    case "close_pane":
      guard let pid = params["paneId"] as? Int else {
        return .failure(ControlError(code: -32602, message: "missing paneId"))
      }
      return target.controlClosePane(paneId: pid)
    case "focus_pane":
      guard let pid = params["paneId"] as? Int else {
        return .failure(ControlError(code: -32602, message: "missing paneId"))
      }
      return target.controlFocusPane(paneId: pid)
    case "close_tab":
      guard let tid = params["tabId"] as? Int else {
        return .failure(ControlError(code: -32602, message: "missing tabId"))
      }
      return target.controlCloseTab(tabId: tid)
    default:
      return nil
    }
  }

  /// エージェント起動（spawn_agent / resume_agent）を dispatch する。非該当は nil。
  /// ここが見るのは param の在否と型だけで、workspace / agent / sessionId の解決は target が返す。
  func runAgent(method: String, params: [String: Any], target: ControlTarget)
    -> Result<Any, ControlError>?
  {
    // 検査は必ず case の中に置く。この関数は dispatch 連鎖の途中にいて**非該当メソッドでも
    // 呼ばれる**ので、switch の外で弾くと未知メソッドが -32601 ではなく -32602 を返し、
    // config 系の workspaceId の意味論まで巻き添えで変わる。
    switch method {
    case "spawn_agent":
      // command は省略可（対象 workspace の実効 default-agent を target が解く）。ただし
      // 非文字列を渡した形は「省略」と同じにしない——黙って別の agent が起きる。
      guard params["command"] == nil || params["command"] is String else {
        return .failure(ControlError(code: -32602, message: "invalid command"))
      }
      if let error = invalidWorkspaceId(params) { return .failure(error) }
      return target.controlSpawnAgent(
        command: params["command"] as? String, workspaceId: params["workspaceId"] as? Int,
        cwd: params["cwd"] as? String)
    case "resume_agent":
      guard let command = params["command"] as? String else {
        return .failure(ControlError(code: -32602, message: "missing command"))
      }
      guard let sessionId = params["sessionId"] as? String else {
        return .failure(ControlError(code: -32602, message: "missing sessionId"))
      }
      if let error = invalidWorkspaceId(params) { return .failure(error) }
      return target.controlResumeAgent(
        command: command, sessionId: sessionId, workspaceId: params["workspaceId"] as? Int,
        cwd: params["cwd"] as? String)
    default:
      return nil
    }
  }

  /// `workspaceId` は省略可（アクティブ）だが、非 Int を「省略」と同じにはしない——未知 id を
  /// -32004 で弾く契約なのに、型違いだけが黙ってアクティブ WS へ逸れて別の場所にタブが生える。
  private func invalidWorkspaceId(_ params: [String: Any]) -> ControlError? {
    guard params["workspaceId"] == nil || params["workspaceId"] is Int else {
      return ControlError(code: -32602, message: "invalid workspaceId")
    }
    return nil
  }

  /// config（列挙・設定）と workspace CRUD を実行する（config CLI 用）。非該当は nil で未知メソッドへ落とす。
  func runConfigWorkspace(method: String, params: [String: Any], target: ControlTarget)
    -> Result<Any, ControlError>?
  {
    switch method {
    case "config_list":
      return target.controlConfigList(workspaceId: params["workspaceId"] as? Int)
    case "config_set":
      guard let key = params["key"] as? String else {
        return .failure(ControlError(code: -32602, message: "missing key"))
      }
      guard let value = params["value"] else {
        return .failure(ControlError(code: -32602, message: "missing value"))
      }
      guard let scope = params["scope"] as? String else {
        return .failure(ControlError(code: -32602, message: "missing scope"))
      }
      return target.controlConfigSet(
        key: key, value: value, scope: scope, workspaceId: params["workspaceId"] as? Int)
    case "create_workspace":
      guard let name = params["name"] as? String else {
        return .failure(ControlError(code: -32602, message: "missing name"))
      }
      return target.controlCreateWorkspace(name: name, rootPath: params["rootPath"] as? String)
    case "rename_workspace":
      guard let wid = params["workspaceId"] as? Int else {
        return .failure(ControlError(code: -32602, message: "missing workspaceId"))
      }
      guard let name = params["name"] as? String else {
        return .failure(ControlError(code: -32602, message: "missing name"))
      }
      return target.controlRenameWorkspace(workspaceId: wid, name: name)
    case "set_workspace_root":
      guard let wid = params["workspaceId"] as? Int else {
        return .failure(ControlError(code: -32602, message: "missing workspaceId"))
      }
      guard let rootPath = params["rootPath"] as? String else {
        return .failure(ControlError(code: -32602, message: "missing rootPath"))
      }
      return target.controlSetWorkspaceRoot(workspaceId: wid, rootPath: rootPath)
    case "remove_workspace":
      guard let wid = params["workspaceId"] as? Int else {
        return .failure(ControlError(code: -32602, message: "missing workspaceId"))
      }
      return target.controlRemoveWorkspace(workspaceId: wid)
    default:
      return nil
    }
  }
}
