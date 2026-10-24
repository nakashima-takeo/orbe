import Foundation
import Observation

/// 自動化と候補の唯一の正（@Observable・main のみ）。`WindowController` が 1 個所有し、制御 API・走らせ役・画面が同じ変異
/// メソッドを呼ぶ——値の検証と不変条件はここだけが持つ。
///
/// 変異はどれも「変わる行を DB に 1 トランザクションで書き、最後に掃除し、通ってからメモリを進める」の 1 経路で行う。書けなければ
/// メモリは変わらず、呼び手に `.unavailable` を返す——逆だと、書けなかった変化が画面にだけ残り、再起動で巻き戻る。出す側の行の
/// 本文は DB にだけ置き、メモリは画面と予定が同期で読む分（部品の状態・覚えている候補）だけを持つ。部品の状態は変わった部品に
/// ついて DB から読み直す（`AutomationMemory.reread`・`recount`）。確定の中でしか使わない事実（読んだ位置・最後の番号・持ち越し）
/// は持たず、使う場で DB から読む。
///
/// DB を使えない（開けない・別の Orbe が持つ・新しい版・運転中に壊れを見つけた）ストアは、自動化 0 件として描き、変異と読みを
/// 理由付きで断る。壊れの退避は次の起動の検査に任せる。
@Observable final class AutomationStore {
  private(set) var automations: [Automation] = []
  /// 定義を読めない自動化。
  private(set) var unreadable: [AutomationUnreadable] = []
  private(set) var proposals: [AutomationProposal] = []
  private(set) var unreadableProposals: [AutomationUnreadableProposal] = []
  /// 覚えている候補を出した判定の部品の持ち主（部品 ID → 自動化 ID。外した部品も、候補に指されている間は持ち主を指す）。
  private(set) var judgeOwners: [AutomationNodeID: Int] = [:]
  private var database: AutomationDatabase?
  /// 使えないときの断り。
  private(set) var unavailableError: AutomationError
  /// DB を使える。
  var available: Bool { database != nil }
  /// 運転中に使えなくなった（走らせ役が全部品の予定を外す）。
  @ObservationIgnored var onUnavailable: () -> Void = {}
  /// 走っている回が確定まで使うもの（確定まで掃除から守る）。走らせ役が渡す。
  @ObservationIgnored var holding: () -> AutomationHolding = { AutomationHolding() }
  /// 変異が通った（走らせ役が、読めば取る行の数え直しの時刻を合わせ直す）。
  @ObservationIgnored var committed: () -> Void = {}

  init(opening: Result<AutomationDatabase.Opened, AutomationError> = AutomationPersistence.open()) {
    switch opening {
    case .success(let opened):
      database = opened.database
      automations = opened.memory.automations
      unreadable = opened.memory.unreadable
      proposals = opened.memory.proposals
      unreadableProposals = opened.memory.unreadableProposals
      judgeOwners = opened.memory.judgeOwners
      unavailableError = Self.brokenError
    case .failure(let error):
      unavailableError = error
    }
  }

  static let brokenError = AutomationError.unavailable(
    "automations are unavailable in this session: the database broke while running; see the log")

  func automation(_ id: Int) -> Automation? {
    automations.first { $0.id == id }
  }

  func index(_ id: Int) throws(AutomationError) -> Int {
    guard let index = automations.firstIndex(where: { $0.id == id }) else {
      if let broken = unreadable.first(where: { $0.id == id }) {
        throw .unreadable(id, broken.reason)
      }
      throw .automationNotFound(id)
    }
    return index
  }

  /// 今のメモリ。
  var memory: AutomationMemory {
    AutomationMemory(
      automations: automations, unreadable: unreadable, proposals: proposals,
      unreadableProposals: unreadableProposals, judgeOwners: judgeOwners)
  }

  var heldLinks: Set<String> { memory.heldLinks }

  // MARK: - 定義

  func create(_ definition: AutomationDefinition, now: Date) throws(AutomationError) -> Automation {
    if let index = definition.parts.firstIndex(where: { $0.id != nil }) {
      throw .invalid("parts[\(index)].id: a new automation has no part ids yet")
    }
    let (name, checked) = try definition.checked()
    let at = TaskItem.storedInstant(now)
    return try commit(sweepingAt: at) { db, memory in
      let id = try db.insertAutomation(name: name, notify: definition.notify, createdAt: at)
      var entities: [AutomationNode] = []
      for (position, item) in checked.enumerated() {
        let defId = try db.insert(action: item.definitionNode.action)
        let nodeId = try db.insertNode(
          of: id, at: position, item.definitionNode, defId: defId, addedAt: at)
        entities.append(AutomationNode(item.definitionNode, id: nodeId, defId: defId))
      }
      let graph = AutomationGraph(checked, entities: entities)
      for node in graph.nodes { try db.setEdges(of: id, to: node.id, node.inputs) }
      let automation = Automation(
        id: id, name: name, notify: definition.notify, graph: graph, pausedAt: nil, version: 1,
        createdAt: at,
        states: Dictionary(
          uniqueKeysWithValues: try graph.nodes.map { ($0.id, try db.state(of: $0.id)) }))
      memory.automations.append(automation)
      try memory.recount(automation.id, db, now: at)
      return memory.automations[memory.automations.count - 1]
    }
  }

  /// 止める・再開する。版は変えない。
  func setPaused(_ id: Int, _ paused: Bool, now: Date) throws(AutomationError) -> Automation {
    let index = try index(id)
    var next = automations[index]
    guard next.paused != paused else { return next }
    next.pausedAt = paused ? TaskItem.storedInstant(now) : nil
    try commit(sweepingAt: nil) { db, memory in
      try db.setPaused(id, at: next.pausedAt)
      memory.automations[index] = next
    }
    return next
  }

  /// 消す。部品をすべて外し（今有効な項目を無効にし、記録を消す）、自動化の行を消す。出どころが無効になった判断待ちの候補は
  /// 下がり、誰も持たなくなった候補は忘れる。定義を読めない自動化も消せる。
  func delete(_ id: Int, now: Date) throws(AutomationError) {
    let nodeIds: [AutomationNodeID]
    if let automation = automation(id) {
      nodeIds = automation.graph.nodes.map(\.id)
    } else if let broken = unreadable.first(where: { $0.id == id }) {
      nodeIds = broken.nodeIds
    } else {
      throw .automationNotFound(id)
    }
    let at = TaskItem.storedInstant(now)
    try commit(sweepingAt: at) { db, memory in
      var invalidated: [Int] = []
      for nodeId in nodeIds {
        invalidated += try db.removeNode(nodeId, at: at)
      }
      try db.deleteAutomation(id)
      memory.automations.removeAll { $0.id == id }
      memory.unreadable.removeAll { $0.id == id }
      try memory.withdraw(originatingIn: invalidated, db)
      try memory.forgetUnheld(db)
    }
  }

  // MARK: - 候補をさばく

  /// 出ている候補を、`workspace` に付けてタスク一覧へ未着手で足す。追加が拒否されたら候補は変わらない。タスクを足した後に
  /// 判断を書けなければ、候補は判断待ちのまま残る（タスクと自動化は別の原本）。
  func accept(_ proposalId: Int, into tasks: TaskStore, workspace: UUID?, now: Date = Date())
    throws(AutomationError) -> TaskItem
  {
    let index = try openIndex(proposalId)
    guard database != nil else { throw unavailableError }
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
      try settle(index, as: .accepted(taskId: task.id), now: now)
    } catch {
      NSLog("[automation] the task \(task.id) was added but the proposal stays open: \(error)")
    }
    return task
  }

  func dismiss(_ proposalId: Int, now: Date = Date()) throws(AutomationError) {
    try settle(try openIndex(proposalId), as: .dismissed, now: now)
  }

  /// 人の判断を 1 件残す。判断待ちでなくなった候補は、どの自動化も持たなければ忘れる。
  private func settle(_ index: Int, as state: AutomationProposal.State, now: Date)
    throws(AutomationError)
  {
    let at = TaskItem.storedInstant(now)
    try commit(sweepingAt: at) { db, memory in
      try db.settle(memory.proposals[index].id, state, at: at)
      memory.proposals[index].state = state
      try memory.forgetUnheld(db)
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

  /// 変異の 1 経路。`body` はメモリの写しを進めながら、変わる行を DB に書く（1 トランザクション）。`sweepingAt`（変異の時刻）が
  /// あれば、覚えている候補のリンクが変わったときに判定の部品の読めば取る行を数え直し（「既に候補がある」で捨てる行が変わる）、
  /// 最後に掃除する。判定の部品の持ち主はいつも読み直す。通ったら写しをメモリにし、通らなければメモリは変わらない。壊れを見つけたら接続を手放してストアを使えなくする。
  /// 検証は呼ぶ前に済ませる（`body` が投げたものはどれも書けなかったことになる）。
  func commit<T>(
    sweepingAt sweep: Date?, _ body: (AutomationDatabase, inout AutomationMemory) throws -> T
  ) throws(AutomationError) -> T {
    guard let database else { throw unavailableError }
    var memory = self.memory
    let holding = self.holding()
    let result: T
    do {
      result = try database.transaction {
        let held = memory.heldLinks
        let result = try body(database, &memory)
        if let sweep {
          if memory.heldLinks != held { try memory.recountJudges(database, now: sweep) }
          try database.sweep(now: sweep, holding: holding)
        }
        memory.judgeOwners = try database.judgeOwners()
        return result
      }
    } catch {
      throw fault(error)
    }
    if memory.automations != automations { automations = memory.automations }
    if memory.unreadable != unreadable { unreadable = memory.unreadable }
    if memory.proposals != proposals { proposals = memory.proposals }
    if memory.unreadableProposals != unreadableProposals {
      unreadableProposals = memory.unreadableProposals
    }
    if memory.judgeOwners != judgeOwners { judgeOwners = memory.judgeOwners }
    committed()
    return result
  }

  /// トランザクションの外で読む。
  func read<T>(_ body: (AutomationDatabase) throws -> T) throws(AutomationError) -> T {
    guard let database else { throw unavailableError }
    do {
      return try body(database)
    } catch {
      throw fault(error)
    }
  }

  private func fault(_ error: Error) -> AutomationError {
    if let error = error as? AutomationError { return error }
    NSLog("[automation] cannot read or save automations: \(error)")
    if let error = error as? SQLiteError, error.isBroken {
      database = nil
      unavailableError = Self.brokenError
      automations = []
      unreadable = []
      proposals = []
      unreadableProposals = []
      judgeOwners = [:]
      onUnavailable()
      return unavailableError
    }
    return .unavailable("could not read or save automations: \(error)")
  }
}

/// 写し——DB の全体をメモリの DB へ写したストア。写しの変異は元の DB に届かない。
extension AutomationStore {
  /// 区切って進める写し。区切りの間に元のストアが書いた分も写しに入る（同じ接続の書き込みは SQLite が写しへ反映する）。
  final class Copy {
    /// 1 区切りのページ数（1 区切りが画面の 1 コマより十分短く済む大きさ）。
    static let pagesPerStep: Int32 = 256

    private let production: AutomationStore
    private let database: SQLiteDatabase
    private let backup: SQLiteBackup

    fileprivate init(production: AutomationStore, database: SQLiteDatabase, backup: SQLiteBackup) {
      self.production = production
      self.database = database
      self.backup = backup
    }

    /// 1 区切り写す。写し終えたら写しのストアを返す。写しのストアのメモリは元のメモリをそのまま使う——元は「DB に書けてから
    /// メモリを進める」を同じ main で行うので、写し終えた時点の元のメモリはその時点の DB と一致する（写しの DB を読み直すと、
    /// 読めば取る行を数える読みが行の数に比例して main を止める）。写し終えた後には呼ばない。
    func step() throws(AutomationError) -> AutomationStore? {
      guard production.available else { throw production.unavailableError }
      do {
        guard try backup.step(pages: Self.pagesPerStep) else { return nil }
        try database.exec("PRAGMA foreign_keys = ON")
      } catch {
        throw .unavailable("could not copy automations: \(error)")
      }
      return AutomationStore(
        opening: .success(
          AutomationDatabase.Opened(
            database: AutomationDatabase(database), memory: production.memory)))
    }
  }

  func copy() throws(AutomationError) -> Copy {
    guard let database else { throw unavailableError }
    do {
      let copy = try SQLiteDatabase.memory()
      return Copy(production: self, database: copy, backup: try database.backup(into: copy))
    } catch {
      throw .unavailable("could not copy automations: \(error)")
    }
  }
}

/// ストアのメモリ——起動時に読んだ全部（`AutomationDatabase.memory`）と、変異の間に進める写し（`AutomationStore.commit`）。
struct AutomationMemory: Equatable {
  var automations: [Automation]
  var unreadable: [AutomationUnreadable] = []
  var proposals: [AutomationProposal]
  var unreadableProposals: [AutomationUnreadableProposal] = []
  /// 覚えている候補を出した判定の部品の持ち主（`AutomationStore.judgeOwners`）。
  var judgeOwners: [AutomationNodeID: Int] = [:]

  func automation(_ id: Int) -> Automation? {
    automations.first { $0.id == id }
  }

  /// 覚えている候補のリンク（読めない候補を含む）。「既に候補がある」はこれで言う。
  var heldLinks: Set<String> {
    Set(proposals.map(\.item.link) + unreadableProposals.map(\.link))
  }

  /// 部品の自分の状態を DB から読み直す（読めば取る行は保つ）。
  mutating func reread(_ nodeId: AutomationNodeID, of id: Int, _ db: AutomationDatabase) throws {
    guard let index = automations.firstIndex(where: { $0.id == id }),
      let pending = automations[index].states[nodeId]?.pending
    else { return }
    var state = try db.state(of: nodeId)
    state.pending = pending
    automations[index].states[nodeId] = state
  }
}
