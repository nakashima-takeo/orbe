import Foundation

/// 制御 API の動詞 1 つ。受ける引数の鍵と型と、応え方を持つ。
struct ControlVerb {
  typealias WindowHandler = (ControlTarget, ControlParams) throws(ControlError) -> Result<
    Any, ControlError
  >
  typealias ConnectionHandler = (ControlServer) -> (Any?, ControlParams, Connection) -> Void
  typealias SilentHandler = (ControlServer) -> (ControlParams) -> Void

  enum Reply {
    /// ウィンドウ（target）を要する。main で実行し、無ければ -32000 no window。
    case window(WindowHandler)
    /// 接続ごとに自分で応える（待つ・ファイルを読む・接続の向こうの報告者を使う・作業場の用意を待ち合わせる）。
    case connection(ConnectionHandler)
    /// 応答を書かない（シェルの補完の打鍵ごとの通知）。断るべき要求は何もしない。
    case silent(SilentHandler)
  }

  let params: [String: ControlParamType]
  let reply: Reply

  init(_ params: [String: ControlParamType], _ reply: Reply) {
    self.params = params
    self.reply = reply
  }

  /// 引数を受けない動詞。
  init(_ reply: Reply) { self.init([:], reply) }
}

extension ControlServer {
  /// 動詞の表。受け口はここだけを引き、無い method は -32601（method 名だけで決まる）。行の鍵はハンドラが読む鍵と
  /// ちょうど同じで、MCP に出す道具の `inputSchema` の欄とも一致する（テストで縛る）。
  static let verbs: [String: ControlVerb] = [
    "list_workspaces": ControlVerb(.window(listWorkspaces)),
    "list_tabs": ControlVerb(["workspaceId": .workspaceId], .window(listTabs)),
    "list_agents": ControlVerb(.window(listAgents)),
    "get_tab_text": ControlVerb(["tabId": .int, "scrollback": .bool], .window(getTabText)),
    "send_text": ControlVerb(["tabId": .int, "text": .string], .window(sendText)),
    "send_key": ControlVerb(["tabId": .int, "key": .string], .window(sendKey)),
    "spawn": ControlVerb(
      ["workspaceId": .workspaceId, "cwd": .string, "command": .string, "select": .bool],
      .window(spawn)),
    "spawn_agent": ControlVerb(
      ["command": .string, "workspaceId": .workspaceId, "cwd": .string, "timeoutMs": .int],
      .connection(spawnAgent)),
    "resume_agent": ControlVerb(
      [
        "command": .string, "sessionId": .string, "workspaceId": .workspaceId, "cwd": .string,
        "timeoutMs": .int,
      ], .connection(resumeAgent)),
    "activate_workspace": ControlVerb(
      ["workspaceId": .workspaceId], .window(activateWorkspace)),
    "prompt_agent": ControlVerb(
      ["tabId": .int, "text": .string, "timeoutMs": .int], .connection(promptAgent)),
    "wait_for_event": ControlVerb(
      ["tabId": .int, "kinds": .strings, "value": .string, "after": .int, "timeoutMs": .int],
      .connection(waitForEvent)),
    "session_log": ControlVerb(
      ["since": .string, "until": .string, "limit": .int, "sessionId": .string],
      .connection(sessionLog)),
    "restore_sessions": ControlVerb(["sessionIds": .strings], .window(restoreSessions)),
    "focus_tab": ControlVerb(["tabId": .int], .window(focusTab)),
    "close_tab": ControlVerb(["tabId": .int], .window(closeTab)),
    "open_file": ControlVerb(["tabId": .int, "path": .string], .window(openFile)),
    "config_list": ControlVerb(["workspaceId": .workspaceId], .window(configList)),
    "config_set": ControlVerb(
      ["key": .string, "value": .any, "scope": .string, "workspaceId": .workspaceId],
      .window(configSet)),
    "create_workspace": ControlVerb(
      ["name": .string, "rootPath": .string], .window(createWorkspace)),
    "rename_workspace": ControlVerb(
      ["workspaceId": .workspaceId, "name": .string], .window(renameWorkspace)),
    "set_workspace_root": ControlVerb(
      ["workspaceId": .workspaceId, "rootPath": .string], .window(setWorkspaceRoot)),
    "remove_workspace": ControlVerb(["workspaceId": .workspaceId], .window(removeWorkspace)),
    "report_agent": ControlVerb(
      [
        "tabId": .int, "agent": .string, "state": .string, "sessionId": .string,
        "message": .string, "messageSource": .string, "reason": .string,
      ], .connection(reportAgent)),
    "completion_update": ControlVerb(
      ["tabId": .int, "buffer": .string, "cursor": .int], .silent(completionUpdate)),
    "completion_end": ControlVerb(["tabId": .int], .silent(completionEnd)),
    "completion_accept": ControlVerb(
      ["tabId": .int, "advance": .bool], .connection(completionAccept)),
    "list_tasks": ControlVerb(["workspaceId": .workspaceId], .window(listTasks)),
    "add_task": ControlVerb(
      [
        "title": .string, "status": .string, "priority": .string, "due": .clearable(.string),
        "waitingReason": .clearable(.string), "description": .string, "links": .objects,
        "workspaceId": .clearable(.workspaceId), "worktree": .string,
      ], .window(addTask)),
    "update_task": ControlVerb(
      [
        "taskId": .int, "title": .string, "status": .string, "priority": .string,
        "due": .clearable(.string), "waitingReason": .clearable(.string), "description": .string,
        "links": .objects, "workspaceId": .clearable(.workspaceId),
        "worktree": .clearable(.string),
      ], .window(updateTask)),
    "set_wait_condition": ControlVerb(
      ["taskId": .int, "condition": .clearable(.object)], .window(setWaitCondition)),
    "delete_task": ControlVerb(["taskId": .int], .window(deleteTask)),
    "start_task": ControlVerb(
      [
        "taskId": .int, "branch": .string, "repo": .string, "agent": .string, "prompt": .string,
      ], .connection(startTask)),
    "list_automations": ControlVerb(.window(listAutomations)),
    "set_automation": ControlVerb(
      ["automationId": .int, "version": .int, "definition": .object], .window(setAutomation)),
    "list_automation_runs": ControlVerb(
      ["automationId": .int, "nodeKey": .string, "before": .int, "limit": .int],
      .window(listAutomationRuns)),
    "run_automation": ControlVerb(
      ["automationId": .int, "nodeKey": .string], .window(runAutomation)),
    "pause_automation": ControlVerb(
      ["automationId": .int, "nodeKey": .string, "paused": .bool], .window(pauseAutomation)),
    "delete_automation": ControlVerb(["automationId": .int], .window(deleteAutomation)),
    "list_automation_proposals": ControlVerb(
      ["automationId": .int], .window(listAutomationProposals)),
    "try_automation": ControlVerb(
      [
        "automationId": .int, "version": .int, "definition": .object, "from": .strings,
        "to": .strings, "rows": .objects, "limit": .int,
      ], .window(tryAutomation)),
    "get_automation_trial": ControlVerb(
      ["trialId": .int, "wait": .bool, "timeoutMs": .int], .connection(automationTrial)),
    "run_tool": ControlVerb(
      ["token": .string, "name": .string, "arguments": .object], .window(runTool)),
    "list_board_widgets": ControlVerb(["workspaceId": .workspaceId], .window(listBoardWidgets)),
    "add_board_widget": ControlVerb(
      ["workspaceId": .workspaceId, "kind": .string], .window(addBoardWidget)),
    "remove_board_widget": ControlVerb(
      ["workspaceId": .workspaceId, "kind": .string], .window(removeBoardWidget)),
  ]
}
