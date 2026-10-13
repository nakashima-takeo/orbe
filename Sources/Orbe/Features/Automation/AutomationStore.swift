import Foundation
import Observation

/// 自動化と候補の唯一の正（@Observable・main のみ）。`WindowController` が 1 個所有し、制御 API・走らせ役・画面が同じ変異
/// メソッドを呼ぶ——値の検証と不変条件はここだけが持つ。変異が成功するたびに即座に保存する。候補の保ち方は
/// `AutomationProposalBook`（タスク候補の出力先）が持つ。
@Observable final class AutomationStore {
  private(set) var automations: [Automation]
  private var book: AutomationProposalBook
  private var nextAutomationId: Int

  var proposals: [AutomationProposal] { book.proposals }

  init(file: AutomationsFile? = AutomationPersistence.load()) {
    automations = file?.automations ?? []
    book = AutomationProposalBook(
      proposals: file?.proposals ?? [], nextId: file?.nextProposalId ?? 1)
    nextAutomationId = file?.nextAutomationId ?? 1
  }

  func automation(_ id: Int) -> Automation? {
    automations.first { $0.id == id }
  }

  // MARK: - 定義

  func create(_ definition: AutomationDefinition, now: Date) throws(AutomationError) -> Automation {
    let automation = Automation(
      id: nextAutomationId, definition: try Self.valid(definition), paused: false,
      createdAt: TaskItem.storedInstant(now), lastFetched: [], reviewAll: false, lastRunAt: nil,
      lastSucceededAt: nil, runs: [])
    nextAutomationId += 1
    automations.append(automation)
    persist()
    return automation
  }

  /// 定義を丸ごと置き換える。何をするか（`AutomationDefinition.work`）が変わったら（`reworked`）、見直しを受ける出力先なら
  /// 次の回は枠の差分を掛けずに見直す。全件見直しの印は新しい出力先で決め直す——見直しを受けない出力先へ替えたら、前から
  /// 立っていた印も下ろす。止めているかは変えない。誰も持たなくなった候補は、その場で忘れる。
  func replace(_ id: Int, with definition: AutomationDefinition) throws(AutomationError) -> (
    automation: Automation, reworked: Bool
  ) {
    guard let index = automations.firstIndex(where: { $0.id == id }) else {
      throw .automationNotFound(id)
    }
    let definition = try Self.valid(definition)
    let reworked = automations[index].definition.work != definition.work
    automations[index].redefine(definition)
    automations[index].reviewAll =
      Self.reviewsAfterRework(definition.sink) && (automations[index].reviewAll || reworked)
    _ = book.forgetUnheld(by: automations)
    persist()
    return (automations[index], reworked)
  }

  func setPaused(_ id: Int, _ paused: Bool) throws(AutomationError) -> Automation {
    guard let index = automations.firstIndex(where: { $0.id == id }) else {
      throw .automationNotFound(id)
    }
    automations[index].paused = paused
    persist()
    return automations[index]
  }

  /// 消す。その自動化だけが持っていた候補は忘れる。
  func delete(_ id: Int) throws(AutomationError) {
    guard let index = automations.firstIndex(where: { $0.id == id }) else {
      throw .automationNotFound(id)
    }
    automations.remove(at: index)
    _ = book.forgetUnheld(by: automations)
    persist()
  }

  // MARK: - 1 回

  /// 枠の差分。この自動化の前回の取得結果に id が無い項目。全件見直しの回と、毎回全件の取得元では掛けない。
  func unseen(of id: Int, in fetched: [AutomationItem]) -> [AutomationItem] {
    guard let automation = automation(id) else { return [] }
    guard !automation.reviewAll, automation.definition.source?.coverage != .everything else {
      return fetched
    }
    let seen = Set(automation.lastFetched.map(\.id))
    return fetched.filter { !seen.contains($0.id) }
  }

  /// 失敗した回。記録と最後に回った時刻だけを進め、取得済みも候補も動かさない。
  func recordFailure(of id: Int, _ run: AutomationRun) {
    guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
    record(run, at: index)
    persist()
  }

  /// 成功した回を確定する。前回の取得結果・全件見直しの印・前回成功の目印を進め、出力先の確定（`sink`。この時点の候補と
  /// 自動化を受けて記録を返す）と回の記録を 1 度に保存する。
  func commit(
    _ id: Int, _ run: AutomationRun, fetched: [AutomationItem],
    sink: (inout AutomationProposalBook, [Automation]) -> AutomationSinkReport?
  ) {
    guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
    var run = run
    automations[index].lastFetched = fetched.map { AutomationSeen(id: $0.id, link: $0.link) }
    automations[index].reviewAll = false
    automations[index].lastSucceededAt = run.startedAt
    run.sink = sink(&book, automations)
    record(run, at: index)
    persist()
  }

  private func record(_ run: AutomationRun, at index: Int) {
    automations[index].runs.insert(run, at: 0)
    if automations[index].runs.count > Automation.retainedRuns {
      automations[index].runs.removeLast(automations[index].runs.count - Automation.retainedRuns)
    }
    automations[index].lastRunAt = run.startedAt
  }

  // MARK: - 候補をさばく

  /// 出ている候補を、`workspace` に付けてタスク一覧の `position` へ未着手で足す。追加が拒否されたら候補も累計も変わらない。
  func accept(
    _ proposalId: Int, into tasks: TaskStore, workspace: UUID?, at position: TaskStore.AddPosition
  ) throws(AutomationError) -> TaskItem {
    let index = try openIndex(proposalId)
    let proposal = proposals[index]
    var draft = TaskDraft(title: proposal.title)
    draft.due = proposal.due
    draft.workspace = workspace
    draft.description = proposal.item.link + "\n\n" + proposal.item.body
    let task: TaskItem
    do {
      task = try tasks.add(draft, at: position)
    } catch {
      switch error {
      case .invalid(let message): throw .invalid(message)
      case .notFound(let id): throw .invalid("task not found: \(id)")
      }
    }
    book.proposals[index].state = .accepted(taskId: task.id)
    tally(proposal, \.accepted)
    persist()
    return task
  }

  func dismiss(_ proposalId: Int) throws(AutomationError) {
    let index = try openIndex(proposalId)
    book.proposals[index].state = .dismissed
    tally(proposals[index], \.dismissed)
    persist()
  }

  /// さばいた候補を、出した自動化の累計に数える（棚に出していた自動化ではなく）。出した自動化が居なければ数えない。
  private func tally(
    _ proposal: AutomationProposal, _ outcome: WritableKeyPath<AutomationTaskCandidatesState, Int>
  ) {
    guard let index = automations.firstIndex(where: { $0.id == proposal.automationId }) else {
      return
    }
    automations[index].tally(outcome)
  }

  private func openIndex(_ proposalId: Int) throws(AutomationError) -> Int {
    guard let index = proposals.firstIndex(where: { $0.id == proposalId }) else {
      throw .proposalNotFound(proposalId)
    }
    guard proposals[index].state == .open else { throw .proposalNotOpen(proposalId) }
    return index
  }

  private func persist() {
    AutomationPersistence.save(
      AutomationsFile(
        version: AutomationPersistence.version, nextAutomationId: nextAutomationId,
        nextProposalId: book.nextId, automations: automations, proposals: book.proposals))
  }

  // MARK: - 検証

  /// 名前と段の名前はタスクのタイトルと同じ 1 行の規則（前後の空白を除いて保存）。agent は裏で回せる CLI だけ。取得元の
  /// agent のツールは MCP のツールの完全名だけ。出力先ごとの要件はその出力先が見る。
  static func valid(_ definition: AutomationDefinition) throws(AutomationError)
    -> AutomationDefinition
  {
    var definition = definition
    definition.name = try line(definition.name, "name")
    if let source = definition.source { try check(source) }
    for (index, step) in definition.steps.enumerated() {
      let role = "steps[\(index)]"
      definition.steps[index].name = try line(step.name, "\(role).name")
      switch step.method {
      case .command(let command):
        do throws(BackgroundJobError) {
          try BackgroundJob.command(command).validate()
        } catch {
          throw .invalid("\(role): \(error.message)")
        }
      case .agent(let agent):
        try checkAgent(agent.cli, model: agent.model, role)
        guard !isBlank(agent.instruction) else { throw .invalid("\(role): instruction is empty") }
      }
    }
    switch definition.sink {
    case .taskCandidates: try AutomationTaskCandidates.check(definition)
    case .command(let command): try AutomationCommandSinkRun.check(command)
    }
    do throws(BackgroundJobError) {
      try definition.trigger.validate()
    } catch {
      throw .invalid("trigger: \(error.message)")
    }
    return definition
  }

  /// 書き換えの後に全件を見直す出力先か。
  private static func reviewsAfterRework(_ sink: AutomationSink) -> Bool {
    switch sink {
    case .taskCandidates: AutomationTaskCandidates.reviewsAfterRework
    case .command: AutomationCommandSinkRun.reviewsAfterRework
    }
  }

  private static func check(_ source: AutomationSource) throws(AutomationError) {
    switch source.method {
    case .command(let command):
      do throws(BackgroundJobError) {
        try BackgroundJob.command(command).validate()
      } catch {
        throw .invalid("source: \(error.message)")
      }
    case .agent(let agent):
      try checkAgent(agent.cli, model: agent.model, "source")
      guard !agent.tools.isEmpty else { throw .invalid("source: tools are empty") }
      if let tool = agent.tools.first(where: { !isMCPToolName($0) }) {
        throw .invalid(
          "source: \(tool) is not a full MCP tool name (mcp__<server>__<tool>); built-in tools, "
            + "whole servers and wildcards are refused so that fetched text cannot make the "
            + "fetcher write anything")
      }
      guard !isBlank(agent.request) else { throw .invalid("source: request is empty") }
    }
  }

  private static func line(_ text: String, _ field: String) throws(AutomationError) -> String {
    do throws(TaskStoreError) {
      return try TaskStore.validTitle(text)
    } catch {
      throw .invalid("\(field) must be a single non-empty line")
    }
  }

  /// モデルは省略できる（既定は `AutomationDefinition.model`）。書くなら空でないこと。
  private static func checkAgent(_ cli: String, model: String?, _ role: String)
    throws(AutomationError)
  {
    switch AgentCatalog.profile(cli)?.headless {
    case .runs: break
    case .refuses(let reason):
      throw .invalid("\(role): \(cli) cannot run in the background (\(reason.message))")
    case nil: throw .invalid("\(role): agent \(cli) is not supported")
    }
    if let model, isBlank(model) { throw .invalid("\(role): model is empty") }
  }

  /// 取得役は外から届いた文面を読むので、書き込みの手段を渡さないよう、使えるツールを名指しした MCP のツールに限る。
  /// 文字はツール名に使えるもの（英数字・`_`・`-`）だけ——`,` を通すと `--allowedTools` で連結されてサーバー単位の許可に
  /// なり、空白も同じく区切りになる。
  private static func isMCPToolName(_ name: String) -> Bool {
    guard name.hasPrefix("mcp__"),
      name.unicodeScalars.allSatisfy({
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
          || $0 == "_" || $0 == "-"
      })
    else { return false }
    let rest = name.dropFirst("mcp__".count)
    guard let separator = rest.range(of: "__") else { return false }
    return separator.lowerBound > rest.startIndex && separator.upperBound < rest.endIndex
  }

  private static func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
