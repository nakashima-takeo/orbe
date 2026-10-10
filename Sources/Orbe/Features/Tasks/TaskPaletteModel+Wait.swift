import Foundation

/// 右の欄の待ちの条件の箱で開閉する部分。
enum TaskConditionPart: CaseIterable, Hashable {
  /// 「› 確認のコマンド」（開くと実際のコマンド）。
  case command
  /// 「› 実行の記録」（開くと新しい順の記録）。
  case log
}

/// 待ちの条件まわりの操作（会話のタブへ移る・箱の部分の開閉・解けた待ちを続きから始める）。条件の値は画面から変えない。
extension TaskPaletteModel {
  /// 待っている条件を付けた agent の会話（解けた待ちの会話は `continuation(of:)`）。
  func conversation(of task: TaskItem) -> WaitConversation? {
    task.waiting?.condition?.conversation
  }

  /// 待っている条件の会話を今持っているタブ。
  func conversationTab(of task: TaskItem) -> AgentSessionTabs.Tab? {
    conversation(of: task).flatMap { sessionTabs.tabs[$0.sessionId] }
  }

  /// 右の欄の agent の場所に出す agent（会話の行と同じタブを指すものは出さない）。
  func detailAgent(of task: TaskItem) -> WorktreeAgentActivity.Agent? {
    guard let agent = agent(of: task), agent.tabId != conversationTab(of: task)?.tabId else {
      return nil
    }
    return agent
  }

  /// 解けた待ちを続きから始められるなら、その会話（会話が記録され、その CLI が再開できる）。
  func continuation(of task: TaskItem) -> WaitConversation? {
    guard let conversation = task.waitResolution?.waiting.condition?.conversation,
      AgentCatalog.profile(conversation.command) != nil
    else { return nil }
    return conversation
  }

  /// 解けた待ちの会話があるのに続きから始められない理由（作業ディレクトリ・CLI が無い）。
  func continuationBlock(of task: TaskItem) -> TaskPaletteError? {
    continuation(of: task) == nil ? nil : onContinuationBlock(task.id)
  }

  /// ⌘T が続きから始めるか（会話があり、始められる）。始められなければ ⌘T はいつもの ⌘T。
  func continues(_ task: TaskItem) -> Bool {
    continuation(of: task) != nil && continuationBlock(of: task) == nil
  }

  /// 選んでいるタスクの解けた待ちを、条件を付けた会話の続きから始める（⌘T・起きたことの箱のボタン）。
  func continueWait() {
    guard let task = selectedTask, continues(task) else { return }
    leaveEditingForAction()
    error = onContinueWait(task.id)
  }

  /// 会話の行の ↵・クリック。そのタブへ移る（画面は閉じる）。
  func focusConversationTab() {
    guard let task = selectedTask, let tab = conversationTab(of: task) else { return }
    leaveEditingForAction()
    onFocusTab(tab.tabId)
  }

  /// `date` の日から今日までの暦日の差（「2日前の会話」）。
  func days(since date: Date) -> Int {
    TaskItem.DueDate(date, timeZone: timeZone).days(to: today)
  }

  func isConditionPartOpen(_ part: TaskConditionPart) -> Bool {
    openedConditionParts.contains(part)
  }

  /// 箱の部分の ↵・クリック。開閉し、焦点をそこへ移す。
  func toggleConditionPart(_ part: TaskConditionPart) {
    guard selectedTask?.waiting?.condition != nil else { return }
    leaveEditingForAction()
    area = .detail(.condition(part))
    focus()
    if !openedConditionParts.insert(part).inserted { openedConditionParts.remove(part) }
  }
}
