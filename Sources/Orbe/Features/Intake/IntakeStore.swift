import Foundation
import Observation

/// 受信と提案の唯一の正（@Observable・main のみ）。`WindowController` が 1 個所有し、制御 API・走らせ役・画面が同じ変異
/// メソッドを呼ぶ——値の検証と不変条件はここだけが持つ。変異が成功するたびに即座に保存する。
///
/// 提案はリンク単位で全受信を通じて 1 つ。提案が忘れられるのは、そのリンクがどの受信の前回の取得結果からも消えたときだけで、
/// それまではタスクにした・捨てた・対応済みの提案も覚えていて、同じリンクを再び提案しない。
@Observable final class IntakeStore {
  private(set) var intakes: [Intake]
  private(set) var proposals: [IntakeProposal]
  private var nextIntakeId: Int
  private var nextProposalId: Int

  init(file: IntakesFile? = IntakePersistence.load()) {
    intakes = file?.intakes ?? []
    proposals = file?.proposals ?? []
    nextIntakeId = file?.nextIntakeId ?? 1
    nextProposalId = file?.nextProposalId ?? 1
  }

  func intake(_ id: Int) -> Intake? {
    intakes.first { $0.id == id }
  }

  // MARK: - 定義

  func create(_ definition: IntakeDefinition, now: Date) throws(IntakeError) -> Intake {
    let intake = Intake(
      id: nextIntakeId, definition: try Self.valid(definition), paused: false,
      createdAt: TaskItem.storedInstant(now), lastFetched: [], reviewAll: false, lastRunAt: nil,
      runs: [])
    nextIntakeId += 1
    intakes.append(intake)
    persist()
    return intake
  }

  /// 定義を丸ごと置き換える。取得か判定が変わったら（`reworked`）、次の回は取れた全件を新しい判定で見直す。
  /// 止めているかは変えない。
  func replace(_ id: Int, with definition: IntakeDefinition) throws(IntakeError) -> (
    intake: Intake, reworked: Bool
  ) {
    guard let index = intakes.firstIndex(where: { $0.id == id }) else {
      throw .intakeNotFound(id)
    }
    let definition = try Self.valid(definition)
    let old = intakes[index].definition
    let reworked = old.fetch != definition.fetch || old.judge != definition.judge
    intakes[index].definition = definition
    if reworked { intakes[index].reviewAll = true }
    persist()
    return (intakes[index], reworked)
  }

  func setPaused(_ id: Int, _ paused: Bool) throws(IntakeError) -> Intake {
    guard let index = intakes.firstIndex(where: { $0.id == id }) else {
      throw .intakeNotFound(id)
    }
    intakes[index].paused = paused
    persist()
    return intakes[index]
  }

  /// 消す。その受信だけが取っていたリンクの提案は忘れる。
  func delete(_ id: Int) throws(IntakeError) {
    guard let index = intakes.firstIndex(where: { $0.id == id }) else {
      throw .intakeNotFound(id)
    }
    intakes.remove(at: index)
    _ = forgetUnfetched()
    persist()
  }

  // MARK: - 1 回

  /// 判定に回す項目。この受信の前回の取得結果に id が無く（全件見直しの回は問わない）、同じリンクの提案がどこにも無いもの。
  /// 同じリンクの項目が複数あれば最初の 1 件だけ。
  func newItems(of id: Int, in fetched: [IntakeItem]) -> [IntakeItem] {
    guard let intake = intake(id) else { return [] }
    let seen = intake.reviewAll ? [] : Set(intake.lastFetched.map(\.id))
    let proposed = Set(proposals.map(\.item.link))
    var links = Set<String>()
    return fetched.filter {
      !seen.contains($0.id) && !proposed.contains($0.link) && links.insert($0.link).inserted
    }
  }

  /// 取れた項目のリンクを持つ、出ている提案（判定が対応済みにできる相手）。
  func openProposals(in fetched: [IntakeItem]) -> [IntakeProposal] {
    let links = Set(fetched.map(\.link))
    return proposals.filter { $0.state == .open && links.contains($0.item.link) }
  }

  /// 失敗した回。記録と最後に回った時刻だけを進め、取得済みも提案も動かさない。
  func recordFailure(of id: Int, _ run: IntakeRun) {
    guard let index = intakes.firstIndex(where: { $0.id == id }) else { return }
    record(run, at: index)
    persist()
  }

  /// 成功した回を、この時点の状態に当て直して 1 度に保存する。回の途中に他の受信の確定や人のさばきがあっても、
  /// 既に提案のあるリンクへの提案は捨て、出ていない提案は対応済みにしない。提案した時刻は回の終わり。
  func commit(
    _ id: Int, _ run: IntakeRun, fetched: [IntakeItem], judged: [IntakeItem],
    decisions: [IntakeDecision]
  ) {
    guard let index = intakes.firstIndex(where: { $0.id == id }) else { return }
    var run = run
    intakes[index].lastFetched = fetched.map { IntakeSeen(id: $0.id, link: $0.link) }
    intakes[index].reviewAll = false
    for decision in decisions {
      switch decision {
      case .propose(let itemId, let title, let due):
        guard let item = judged.first(where: { $0.id == itemId }) else { continue }
        guard !proposals.contains(where: { $0.item.link == item.link }) else {
          run.judge?.rejected.add("propose \(itemId): \(item.link) is already proposed")
          continue
        }
        proposals.append(
          IntakeProposal(
            id: nextProposalId, intakeId: id, item: item, title: title, due: due,
            proposedAt: TaskItem.storedInstant(run.endedAt), state: .open))
        nextProposalId += 1
        run.judge?.proposed += 1
      case .resolve(let link):
        guard let open = proposals.firstIndex(where: { $0.item.link == link && $0.state == .open })
        else {
          run.judge?.rejected.add("resolve \(link): no open proposal")
          continue
        }
        proposals[open].state = .resolved
        run.judge?.resolved += 1
      }
    }
    run.withdrawn = forgetUnfetched()
    record(run, at: index)
    persist()
  }

  private func record(_ run: IntakeRun, at index: Int) {
    intakes[index].runs.insert(run, at: 0)
    if intakes[index].runs.count > Intake.retainedRuns {
      intakes[index].runs.removeLast(intakes[index].runs.count - Intake.retainedRuns)
    }
    intakes[index].lastRunAt = run.startedAt
  }

  /// どの受信の前回の取得結果にも無いリンクの提案を忘れ、そのうち出ていたものの数を返す。止めた受信の取得結果も数える。
  private func forgetUnfetched() -> Int {
    let fetched = Set(intakes.flatMap { $0.lastFetched.map(\.link) })
    let gone = proposals.filter { !fetched.contains($0.item.link) }
    proposals.removeAll { !fetched.contains($0.item.link) }
    return gone.filter { $0.state == .open }.count
  }

  // MARK: - 読むときに導くもの

  /// 提案を棚に出す受信。提案した受信がまだそのリンクを取っていればそれ、いなければ取っている受信のうち ID が最小のもの。
  func shelf(of proposal: IntakeProposal) -> Intake? {
    let fetching = intakes.filter { $0.lastFetched.contains { $0.link == proposal.item.link } }
    return fetching.first { $0.id == proposal.intakeId } ?? fetching.min { $0.id < $1.id }
  }

  /// 他の受信と前回の取得結果が重なっているリンクの数（重なりのある相手だけ、ID 順）。
  func overlaps(of id: Int) -> [(intake: Intake, count: Int)] {
    guard let intake = intake(id) else { return [] }
    let links = Set(intake.lastFetched.map(\.link))
    return intakes.compactMap { other in
      guard other.id != id else { return nil }
      let count = links.intersection(other.lastFetched.map(\.link)).count
      return count > 0 ? (other, count) : nil
    }
  }

  // MARK: - 提案をさばく

  /// 出ている提案を、`workspace` に付けてタスク一覧の `position` へ未着手で足す。追加が拒否されたら提案は変わらない。
  func accept(
    _ proposalId: Int, into tasks: TaskStore, workspace: UUID?, at position: TaskStore.AddPosition
  ) throws(IntakeError) -> TaskItem {
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
    proposals[index].state = .accepted(taskId: task.id)
    persist()
    return task
  }

  func dismiss(_ proposalId: Int) throws(IntakeError) {
    let index = try openIndex(proposalId)
    proposals[index].state = .dismissed
    persist()
  }

  private func openIndex(_ proposalId: Int) throws(IntakeError) -> Int {
    guard let index = proposals.firstIndex(where: { $0.id == proposalId }) else {
      throw .proposalNotFound(proposalId)
    }
    guard proposals[index].state == .open else { throw .proposalNotOpen(proposalId) }
    return index
  }

  private func persist() {
    IntakePersistence.save(
      IntakesFile(
        version: IntakePersistence.version, nextIntakeId: nextIntakeId,
        nextProposalId: nextProposalId, intakes: intakes, proposals: proposals))
  }

  // MARK: - 検証

  /// 名前はタスクのタイトルと同じ 1 行の規則（前後の空白を除いて保存）。agent は裏で回せる CLI だけ。
  static func valid(_ definition: IntakeDefinition) throws(IntakeError) -> IntakeDefinition {
    var definition = definition
    do throws(TaskStoreError) {
      definition.name = try TaskStore.validTitle(definition.name)
    } catch {
      throw .invalid("name must be a single non-empty line")
    }
    switch definition.fetch {
    case .command(let command):
      do throws(BackgroundJobError) {
        try BackgroundJob.command(command).validate()
      } catch {
        throw .invalid("fetch: \(error.message)")
      }
    case .agent(let agent):
      try checkAgent(agent.cli, model: agent.model, "fetch")
      guard !agent.tools.isEmpty else { throw .invalid("fetch: tools are empty") }
      guard agent.tools.allSatisfy({ !$0.isEmpty }) else {
        throw .invalid("fetch: a tool name is empty")
      }
      guard !isBlank(agent.request) else { throw .invalid("fetch: request is empty") }
    }
    try checkAgent(definition.judge.cli, model: definition.judge.model, "judge")
    guard !isBlank(definition.judge.instruction) else {
      throw .invalid("judge: instruction is empty")
    }
    do throws(BackgroundJobError) {
      try definition.when.validate()
    } catch {
      throw .invalid("when: \(error.message)")
    }
    return definition
  }

  private static func checkAgent(_ cli: String, model: String, _ role: String)
    throws(IntakeError)
  {
    switch AgentCatalog.profile(cli)?.headless {
    case .runs: break
    case .refuses(let reason):
      throw .invalid("\(role): \(cli) cannot run in the background (\(reason.message))")
    case nil: throw .invalid("\(role): agent \(cli) is not supported")
    }
    guard !isBlank(model) else { throw .invalid("\(role): model is empty") }
  }

  private static func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// 判定の出力から読み取った 1 つの決定。
enum IntakeDecision: Equatable {
  case propose(itemId: String, title: String, due: TaskItem.DueDate?)
  case resolve(link: String)
}

extension BackgroundJobError {
  var message: String {
    switch self {
    case .intervalTooShort: "the interval must be at least 1 minute"
    case .noTimesOfDay: "no times of day"
    case .invalidTimeOfDay: "a time of day is out of range"
    case .emptyCommand: "command is empty"
    case .relativeDirectory: "directory is not an absolute path"
    case .unknownAgent(let cli): "agent \(cli) is not supported"
    case .emptyModel: "model is empty"
    case .emptyPrompt: "prompt is empty"
    case .emptyToolName: "a tool name is empty"
    }
  }
}

extension HeadlessRefusal {
  var message: String {
    switch self {
    case .toolsNotAllowListable: "its built-in tools cannot be allow-listed"
    case .noToolOrSessionControl: "it cannot limit tools or skip saving the session"
    }
  }
}
