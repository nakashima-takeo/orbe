import Foundation

/// 解けた待ちの ⌘T（「続きから」）。条件を付けた agent の会話へ、起きたことを最初の入力として届ける。同じ会話が 2 つの
/// タブで同時に動かないよう、その会話のタブがあればそこへ届け、無ければ記録した場所で再開する。
extension WindowController {
  /// 届けられなかった理由はタスク画面のフッターに出す（nil は届けた、または会話のタブへ移った）。
  ///
  /// - 休眠のタブ: 起こすときの再開に最初の入力を 1 度だけ添えて、そのタブへ移る。
  /// - 生きたタブ: そのタブへ移る。会話が今も前面にいると確かで、入力を受けられる状態（完了・休止）のときだけ、
  ///   起きたことを貼り付けて Enter を押す。それ以外（作業中・確認待ち・確かでない）は移るだけで、起きたことを残す。
  /// - タブが無い: 記録した workspace（無ければタスクの、それも無ければ今の workspace）に、記録した作業ディレクトリで
  ///   「再開＋最初の入力」の新しいタブを開いて前面にする。
  func continueWait(taskId: Int) -> TaskPaletteError? {
    guard let task = taskStore.tasks.first(where: { $0.id == taskId }),
      let resolution = task.waitResolution, let condition = resolution.waiting.condition,
      let conversation = condition.conversation
    else { return nil }
    let input = WaitContinueText.firstInput(resolution, l10n: localization, timeZone: .current)
    if let entry = agentSessionTabs.tabs[conversation.sessionId],
      let tab = controlResolveTab(entry.tabId)
    {
      dismissPalette()
      if tab.isDormant {
        tab.addWakeInput(input)
        _ = controlFocusTab(tabId: tab.id)
        taskStore.clearResolution(taskId)
        return nil
      }
      _ = controlFocusTab(tabId: tab.id)
      if tab.conversationIsForeground, tab.surface.surfacePtr != nil,
        tab.agentState == "done" || tab.agentState == "idle"
      {
        tab.surface.controlSendText(input)
        tab.surface.controlSendKey(ControlKey.enter)
        taskStore.clearResolution(taskId)
      }
      return nil
    }
    guard agentLauncher.detectedAgents.contains(where: { $0.command == conversation.command })
    else { return .agentMissing }
    let directory = condition.directory ?? NSHomeDirectory()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return .directoryMissing }
    guard
      let command = AgentCatalog.resumeCommand(
        forAgent: conversation.command, sessionId: conversation.sessionId, firstInput: input)
    else { return .failed }
    let workspace = { (id: UUID?) in
      id.flatMap { id in self.workspaces.firstIndex { $0.persistentId == id } }
    }
    let index = workspace(conversation.workspace) ?? workspace(task.workspace) ?? activeWorkspace
    dismissPalette()
    if let opened = openTab(
      workspaceIndex: index, cwd: directory, command: command,
      env: agentLauncher.launchEnvironment, agent: conversation.command)
    {
      _ = controlFocusTab(tabId: opened.tabId)
    }
    taskStore.clearResolution(taskId)
    return nil
  }
}

/// 会話へ届ける最初の入力（Orbe が UI の言語で組む）。条件の説明・解けた時刻と確認の回数（期限なら期限）と、満たした
/// ときは確認の標準出力（起きたことに残した長さまで）。
enum WaitContinueText {
  static func firstInput(_ resolution: WaitResolution, l10n: LocalizationStore, timeZone: TimeZone)
    -> String
  {
    let condition = resolution.waiting.condition
    let description = condition?.description ?? resolution.waiting.reason
    let checks = condition?.checks ?? 0
    switch resolution.how {
    case .satisfied(let output):
      let head = l10n.format(
        .waitContinueSatisfied, description, time(resolution.at, timeZone), checks)
      let body = output.trimmingCharacters(in: .whitespacesAndNewlines)
      return body.isEmpty ? head : head + "\n" + l10n.string(.waitContinueOutput) + "\n" + body
    case .expired:
      return l10n.format(.waitContinueExpired, description, time(resolution.at, timeZone), checks)
    }
  }

  /// 「10/10 14:02」。
  static func time(_ date: Date, _ timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    return String(format: "%d/%d %d:%02d", c.month!, c.day!, c.hour!, c.minute!)
  }
}
