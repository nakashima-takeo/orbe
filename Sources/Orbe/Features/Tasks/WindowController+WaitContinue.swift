import Foundation

/// 解けた待ちの ⌘T（「続きから」）。条件を付けた agent の会話へ、起きたことを最初の入力として届ける。同じ会話が 2 つの
/// タブで同時に動かないよう、その会話のタブがあればそこへ届け、無ければ記録した場所で再開する。秘書の会話が付けた条件は
/// 秘書の係へ渡す。
extension WindowController {
  /// 続きから始められない理由（nil は始められる）。始められないタスクの ⌘T は、いつもの ⌘T（worktree パレット）を開く。
  ///
  /// - 秘書の会話: claude が見つかること。
  /// - 会話のタブがある: 何も要らない（そのタブへ移る・届ける）。
  /// - タブが無い: 会話の CLI が見つかり、記録した作業ディレクトリがあること。
  func continuationBlock(taskId: Int) -> TaskPaletteError? {
    guard let task = taskStore.tasks.first(where: { $0.id == taskId }),
      let condition = task.waitResolution?.waiting.condition,
      let conversation = condition.conversation
    else { return .failed }
    if conversation.secretary { return secretaryClaude == nil ? .agentMissing : nil }
    if let entry = agentSessionTabs.tabs[conversation.sessionId],
      controlResolveTab(entry.tabId) != nil
    {
      return nil
    }
    guard agentLauncher.detectedAgents.contains(where: { $0.command == conversation.command })
    else { return .agentMissing }
    var isDirectory: ObjCBool = false
    guard let directory = condition.directory,
      FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return .directoryMissing }
    return nil
  }

  /// 届けられなかった理由はタスク画面のフッターに出す（nil は届けた、会話のタブへ移った、または秘書の係へ渡した）。
  ///
  /// - 秘書の会話: 起きたことを出どころ「待ちの条件」の頼みとして秘書の係へ渡し（溜める・1 件ずつ・/clear の後の
  ///   会話へ届く）、秘書のタブへ移る。秘書の会話を 2 本にしない。
  /// - 休眠のタブ: 起こすときの再開に最初の入力を 1 度だけ添えて、そのタブへ移る。
  /// - 生きたタブ: そのタブへ移る。会話へ今貼ってよい（`TerminalTab.acceptsConversationInput`）ときだけ、起きたことを
  ///   貼り付けて Enter を押す。それ以外（作業中・確認待ち・agent が前面にいない）は移るだけで、起きたことを残す。
  /// - タブが無い: 記録した workspace（無ければタスクの、それも無ければ今の workspace）に、記録した作業ディレクトリで
  ///   会話を最初の入力付きで再開する新しいタブを開いて前面にする。
  func continueWait(taskId: Int) -> TaskPaletteError? {
    if let block = continuationBlock(taskId: taskId) { return block }
    guard let task = taskStore.tasks.first(where: { $0.id == taskId }),
      let resolution = task.waitResolution, let condition = resolution.waiting.condition,
      let conversation = condition.conversation
    else { return nil }
    let input = WaitContinueText.firstInput(resolution, l10n: localization, timeZone: .current)
    if conversation.secretary {
      do {
        _ = try secretary.ask(.wait(input))
      } catch {
        return error == .claudeMissing ? .agentMissing : .failed
      }
      dismissPalette()
      if let tabId = secretary.tabId { _ = controlFocusTab(tabId: tabId) }
      taskStore.clearResolution(taskId)
      return nil
    }
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
      if tab.acceptsConversationInput {
        tab.surface.controlSendText(input)
        tab.surface.controlSendKey(ControlKey.enter)
        taskStore.clearResolution(taskId)
      }
      return nil
    }
    let workspace = { (id: UUID?) in
      id.flatMap { id in self.workspaces.firstIndex { $0.persistentId == id } }
    }
    let index = workspace(conversation.workspace) ?? workspace(task.workspace) ?? activeWorkspace
    dismissPalette()
    guard
      let opened = openResumedTab(
        AgentSession(command: conversation.command, sessionId: conversation.sessionId),
        workspaceIndex: index, cwd: condition.directory, firstInput: input)
    else { return .failed }
    _ = controlFocusTab(tabId: opened.tabId)
    taskStore.clearResolution(taskId)
    return nil
  }
}

/// 会話へ届ける最初の入力（Orbe が UI の言語で組む）。条件の説明・解けた時刻と確認の回数（期限なら期限）と、満たした
/// ときは確認の標準出力（起きたことに残した長さまで）。改行・タブ以外の制御文字（C0・DEL・C1）は空白にする——起動
/// 引数の NUL はそこで引数を切って再開を壊し、貼る経路では端末の制御として届くため。
enum WaitContinueText {
  static func firstInput(_ resolution: WaitResolution, l10n: LocalizationStore, timeZone: TimeZone)
    -> String
  {
    let condition = resolution.waiting.condition
    let description = condition?.description ?? resolution.waiting.reason
    let checks = condition?.checks ?? 0
    let text: String
    switch resolution.how {
    case .satisfied(let output):
      let head = l10n.format(
        .waitContinueSatisfied, description, time(resolution.at, timeZone), checks)
      let body = output.trimmingCharacters(in: .whitespacesAndNewlines)
      text = body.isEmpty ? head : head + "\n" + l10n.string(.waitContinueOutput) + "\n" + body
    case .expired:
      text = l10n.format(
        .waitContinueExpired, description, time(resolution.at, timeZone), checks)
    }
    return String(
      String.UnicodeScalarView(
        text.unicodeScalars.map { isControl($0) ? " " : $0 }))
  }

  private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    guard scalar != "\n", scalar != "\t" else { return false }
    return scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
  }

  /// 「10/10 14:02」。
  static func time(_ date: Date, _ timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    return String(format: "%d/%d %d:%02d", c.month!, c.day!, c.hour!, c.minute!)
  }
}
