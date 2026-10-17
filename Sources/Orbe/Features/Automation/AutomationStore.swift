import Foundation
import Observation

/// 自動化と候補の唯一の正（@Observable・main のみ）。`WindowController` が 1 個所有し、制御 API・走らせ役・画面が同じ変異
/// メソッドを呼ぶ——値の検証と不変条件はここだけが持つ。
///
/// 変異はどれも「変わる行を DB に 1 トランザクションで書き、通ってからメモリを進める」の 1 経路で行う。書けなければメモリは
/// 変わらず、呼び手に `.unavailable` を返す——逆だと、書けなかった変化が画面にだけ残り、再起動で巻き戻る。溜まりの行の本文は
/// DB にだけ置き、メモリは件数だけを持つ。
///
/// DB を開けなかった（別の Orbe が持つ・確かめられない）か、運転中に壊れを見つけたストアは使えない: 自動化 0 件として描き、
/// 変異を断る。壊れの退避は次の起動の検査に任せる。
@Observable final class AutomationStore {
  private(set) var automations: [Automation] = []
  private(set) var proposals: [AutomationProposal] = []
  private(set) var available: Bool
  @ObservationIgnored private var database: AutomationDatabase?
  /// 運転中に使えなくなった（走らせ役が全部品の予定を外す）。
  @ObservationIgnored var onUnavailable: () -> Void = {}

  init(opened: AutomationDatabase.Opened? = AutomationPersistence.open()) {
    database = opened?.database
    available = opened != nil
    automations = opened?.snapshot.automations ?? []
    proposals = opened?.snapshot.proposals ?? []
  }

  func automation(_ id: Int) -> Automation? {
    automations.first { $0.id == id }
  }

  func index(_ id: Int) throws(AutomationError) -> Int {
    guard let index = automations.firstIndex(where: { $0.id == id }) else {
      throw .automationNotFound(id)
    }
    return index
  }

  // MARK: - 定義

  func create(_ definition: AutomationDefinition, now: Date) throws(AutomationError) -> Automation {
    let (name, graph) = try definition.checked()
    let at = TaskItem.storedInstant(now)
    let parts = Dictionary(
      uniqueKeysWithValues: graph.nodes.map { ($0.key, AutomationPartState(addedAt: at)) })
    let draft = Automation(
      id: 0, name: name, notify: definition.notify, graph: graph, paused: false, createdAt: at,
      tally: AutomationTally(), parts: parts)
    return try commit { db, memory in
      let id = try db.insert(draft)
      for (key, state) in parts { try db.put(part: key, of: id, state) }
      let automation = Automation(
        id: id, name: name, notify: definition.notify, graph: graph, paused: false, createdAt: at,
        tally: AutomationTally(), parts: parts)
      memory.automations.append(automation)
      return automation
    }
  }

  /// 定義を丸ごと置き換えたときの、部品ごとの変化。
  struct Replaced {
    let automation: Automation
    /// 何をするかが変わった部品。決まりを外した印を下ろした。
    let reworked: [String]
    /// 足した部品。足した時刻から数える。
    let added: [String]
    /// 消した部品。状態・溜まり・記録を消した。
    let removed: [String]
  }

  /// 定義を丸ごと置き換える。残る部品の前回の出力と溜まりには触れない（ほかの部品の溜まりにある、消えた部品から来た行も
  /// そのまま）。判定の部品が 1 つも無くなれば累計を 0 に戻す。誰も持たなくなった候補は、その場で忘れる。止めているかは変えない。
  func replace(_ id: Int, with definition: AutomationDefinition, now: Date) throws(AutomationError)
    -> Replaced
  {
    let index = try index(id)
    let (name, graph) = try definition.checked()
    let old = automations[index]
    let reworked = AutomationGraph.reworked(from: old.graph, to: graph)
    let removed = old.graph.nodes.map(\.key).filter { graph.node($0) == nil }
    let added = graph.nodes.map(\.key).filter { old.graph.node($0) == nil }
    var next = old
    next.name = name
    next.notify = definition.notify
    next.graph = graph
    for key in removed { next.parts[key] = nil }
    let at = TaskItem.storedInstant(now)
    for key in added { next.parts[key] = AutomationPartState(addedAt: at) }
    let unmarked = reworked.filter { next.parts[$0]?.breach != nil }
    for key in unmarked { next.parts[key]?.breach = nil }
    if !next.judges { next.tally = AutomationTally() }
    try commit { db, memory in
      memory.automations[index] = next
      try db.update(next)
      for key in removed { try db.delete(part: key, of: id) }
      for key in added + unmarked { try db.put(part: key, of: id, next.state(key)) }
      try memory.forgetUnheld(db)
    }
    return Replaced(automation: next, reworked: reworked, added: added, removed: removed)
  }

  func setPaused(_ id: Int, _ paused: Bool) throws(AutomationError) -> Automation {
    let index = try index(id)
    var next = automations[index]
    next.paused = paused
    try commit { db, memory in
      try db.update(next)
      memory.automations[index] = next
    }
    return next
  }

  /// 消す。その部品の状態・溜まり・記録も消え、その自動化だけが持っていた候補は忘れる。
  func delete(_ id: Int) throws(AutomationError) {
    let index = try index(id)
    try commit { db, memory in
      try db.delete(automation: id)
      memory.automations.remove(at: index)
      try memory.forgetUnheld(db)
    }
  }

  // MARK: - 候補をさばく

  /// 出ている候補を、`workspace` に付けてタスク一覧へ未着手で足す。追加が拒否されたら候補も累計も変わらない。タスクを足した後に
  /// 候補を書けなければ、候補は判断待ちのまま残る（タスクと自動化は別の原本）。
  func accept(_ proposalId: Int, into tasks: TaskStore, workspace: UUID?) throws(AutomationError)
    -> TaskItem
  {
    let index = try openIndex(proposalId)
    guard database != nil else { throw Self.unavailableError }
    let proposal = proposals[index]
    var draft = TaskDraft(title: proposal.title)
    draft.due = proposal.due
    draft.workspace = workspace
    draft.description = proposal.item.link + "\n\n" + proposal.item.body
    let task: TaskItem
    do {
      task = try tasks.add(draft)
    } catch {
      switch error {
      case .invalid(let message): throw .invalid(message)
      case .notFound(let id): throw .invalid("task not found: \(id)")
      }
    }
    do throws(AutomationError) {
      try decide(index, as: .accepted(taskId: task.id), \.accepted)
    } catch {
      NSLog("[automation] the task \(task.id) was added but the proposal stays open: \(error)")
    }
    return task
  }

  func dismiss(_ proposalId: Int) throws(AutomationError) {
    try decide(try openIndex(proposalId), as: .dismissed, \.dismissed)
  }

  /// さばいた候補を、出した自動化の累計に数える（棚に出していた自動化ではなく）。出した自動化が居ない・判定の部品を持たなく
  /// なっていれば数えない。
  private func decide(
    _ index: Int, as state: AutomationProposal.State,
    _ outcome: WritableKeyPath<AutomationTally, Int>
  ) throws(AutomationError) {
    try commit { db, memory in
      memory.proposals[index].state = state
      try db.update(proposal: memory.proposals[index])
      let issuer = memory.proposals[index].automationId
      guard let owner = memory.automations.firstIndex(where: { $0.id == issuer && $0.judges })
      else { return }
      memory.automations[owner].tally[keyPath: outcome] += 1
      try db.update(memory.automations[owner])
    }
  }

  private func openIndex(_ proposalId: Int) throws(AutomationError) -> Int {
    guard let index = proposals.firstIndex(where: { $0.id == proposalId }) else {
      throw .proposalNotFound(proposalId)
    }
    guard proposals[index].state == .open else { throw .proposalNotOpen(proposalId) }
    return index
  }

  // MARK: - 書き込み

  private static let unavailableError = AutomationError.unavailable(
    "automations are unavailable in this session (another Orbe holds them, or their database "
      + "could not be opened); see the log")

  /// 変異の 1 経路。`body` はメモリの写しを進めながら、変わる行を DB に書く（1 トランザクション）。通ったら写しをメモリにし、
  /// 通らなければメモリは変わらない。壊れを見つけたら接続を手放してストアを使えなくする。検証は呼ぶ前に済ませる（`body` が
  /// 投げたものはどれも書けなかったことになる）。
  func commit<T>(_ body: (AutomationDatabase, inout AutomationMemory) throws -> T)
    throws(AutomationError) -> T
  {
    guard let database else { throw Self.unavailableError }
    var memory = AutomationMemory(automations: automations, proposals: proposals)
    let result: T
    do {
      result = try database.transaction { try body(database, &memory) }
    } catch {
      throw fault(error)
    }
    if memory.automations != automations { automations = memory.automations }
    if memory.proposals != proposals { proposals = memory.proposals }
    return result
  }

  /// トランザクションの外で読む。
  func read<T>(_ body: (AutomationDatabase) throws -> T) throws(AutomationError) -> T {
    guard let database else { throw Self.unavailableError }
    do {
      return try body(database)
    } catch {
      throw fault(error)
    }
  }

  private func fault(_ error: Error) -> AutomationError {
    NSLog("[automation] cannot save automations: \(error)")
    if let error = error as? SQLiteError, error.isBroken {
      database = nil
      available = false
      automations = []
      proposals = []
      onUnavailable()
      return Self.unavailableError
    }
    return .unavailable("could not save automations: \(error)")
  }
}

/// 変異の間のメモリの写し（`AutomationStore.commit`）。
struct AutomationMemory {
  var automations: [Automation]
  var proposals: [AutomationProposal]

  func index(_ id: Int) -> Int? {
    automations.firstIndex { $0.id == id }
  }
}
