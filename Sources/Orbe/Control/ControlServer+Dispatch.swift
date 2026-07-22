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
