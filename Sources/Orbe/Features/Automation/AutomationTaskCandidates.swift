import Foundation

/// タスク候補の出力先の 1 回。項目は取得元の `id` でたどり、リンクと本文はいつも取得元の項目から取る——段が作った文や
/// リンクを候補に入れないため。
final class AutomationTaskCandidates: AutomationSinkRun {
  private let store: AutomationStore
  private let automationId: Int
  private var fetched: [AutomationItem] = []
  private var fresh: [AutomationItem] = []
  private var open: [AutomationProposal] = []
  private var rejected = AutomationRejections()

  init(store: AutomationStore, automationId: Int) {
    self.store = store
    self.automationId = automationId
  }

  /// 判定を直したら、今の集合を見直して候補を出し直す（既に候補のあるリンクは取り込みで除く）。
  static let reviewsAfterRework = true

  /// 要件。取得元が要り、取得の性質は新着の流れか今の集合（毎回全件で候補をどう保つかは決めていない）。段は 1 つ以上。
  static func check(_ definition: AutomationDefinition) throws(AutomationError) {
    guard let source = definition.source else {
      throw .invalid("sink taskCandidates: a source is required")
    }
    guard source.coverage != .everything else {
      throw .invalid("sink taskCandidates: the coverage must be newArrivals or currentSet")
    }
    guard !definition.steps.isEmpty else {
      throw .invalid("sink taskCandidates: at least one step is required")
    }
  }

  /// 同じリンクの候補がどこにも無い項目。同じ回に同じリンクが複数あれば最初の 1 件だけ。
  func admit(_ items: [AutomationItem], fetched: [AutomationItem]) -> [AutomationItem] {
    self.fetched = fetched
    let proposed = Set(store.proposals.map(\.item.link))
    var links = Set<String>()
    fresh = items.filter { !proposed.contains($0.link) && links.insert($0.link).inserted }
    return fresh
  }

  /// `id` が今回の新しい項目の行だけを渡す。判断待ちの候補はこの時点で取る。
  func prepare(_ rows: [String]) -> [String] {
    open = store.openProposals(of: automationId, in: fetched)
    let ids = Set(fresh.map(\.id))
    return rows.filter { row in
      guard let id = AutomationPrompts.id(of: row) else {
        rejected.add("input without an id")
        return false
      }
      guard ids.contains(id) else {
        rejected.add("input \(id): not a new item")
        return false
      }
      return true
    }
  }

  func prompt(instruction: String, rows: [String], now: Date, timeZone: TimeZone) -> String {
    AutomationPrompts.judge(
      instruction: instruction, rows: rows, open: open, now: now, timeZone: timeZone)
  }

  /// JSON の行として読めた数を数える。全行が形違いでも回は失敗にせず、候補なしとする。
  func read(_ text: String) -> AutomationSinkReading<[AutomationDecision]> {
    let (rows, malformed) = AutomationPrompts.readRows(text)
    let (decisions, rejected) = AutomationPrompts.readJudge(
      rows, itemIds: Set(fresh.map(\.id)), open: open)
    self.rejected.add(rejected)
    return .output(decisions, count: rows.count, rejected: malformed)
  }

  /// 候補は確定で覚えるので、届けはすぐ終わる。
  func deliver(
    _ output: [AutomationDecision], completion: @escaping (AutomationSinkFailure?) -> Void
  ) -> BackgroundRunHandle {
    completion(nil)
    return BackgroundRunHandle {}
  }

  /// この時点の状態に当て直す。回の途中に他の自動化の確定や人のさばきがあっても、既に候補のあるリンクへの候補は捨て、
  /// 出ていない候補は対応済みにしない。候補を出した時刻は回の終わり。
  func commit(
    _ output: [AutomationDecision]?, into book: inout AutomationProposalBook,
    automations: [Automation], endedAt: Date
  ) -> AutomationSinkReport? {
    var report = AutomationTaskCandidatesReport(rejected: rejected)
    for decision in output ?? [] {
      switch decision {
      case .propose(let itemId, let title, let due):
        guard let item = fresh.first(where: { $0.id == itemId }) else { continue }
        guard !book.proposals.contains(where: { $0.item.link == item.link }) else {
          report.rejected.add("propose \(itemId): \(item.link) is already proposed")
          continue
        }
        book.proposals.append(
          AutomationProposal(
            id: book.nextId, automationId: automationId, item: item, title: title, due: due,
            proposedAt: TaskItem.storedInstant(endedAt), state: .open))
        book.nextId += 1
        report.proposed += 1
      case .resolve(let link):
        guard
          let open = book.proposals.firstIndex(where: { $0.item.link == link && $0.state == .open })
        else {
          report.rejected.add("resolve \(link): no open proposal")
          continue
        }
        book.proposals[open].state = .resolved
        report.resolved += 1
      }
    }
    report.withdrawn = book.forgetUnheld(by: automations)
    return .taskCandidates(report)
  }
}

/// 判定の出力から読み取った 1 つの決定。
enum AutomationDecision: Equatable {
  case propose(itemId: String, title: String, due: TaskItem.DueDate?)
  case resolve(link: String)
}

/// 候補の帳面（候補と次に振る ID）。`AutomationStore` が持ち、確定のときだけタスク候補の出力先に貸す。
///
/// 候補はリンク単位で全自動化を通じて 1 つ。候補が忘れられるのは、どの自動化も候補を持たなくなったときだけで、それまでは
/// タスクにした・捨てた・対応済みの候補も覚えていて、同じリンクを再び候補にしない。
struct AutomationProposalBook: Equatable {
  var proposals: [AutomationProposal]
  var nextId: Int

  /// どの自動化も持たない候補を忘れ、そのうち出ていたものの数を返す。止めた自動化も持つ。
  mutating func forgetUnheld(by automations: [Automation]) -> Int {
    let held = { (proposal: AutomationProposal) in
      automations.contains { Self.holds($0, proposal) }
    }
    let withdrawn = proposals.filter { $0.state == .open && !held($0) }.count
    proposals.removeAll { !held($0) }
    return withdrawn
  }

  /// 自動化が候補を持っているか。出力先がタスク候補の自動化だけが持つ——前回の取得結果にリンクがあるか、新着の流れの
  /// 自動化が出してまだ人の判断待ちのものか。
  static func holds(_ automation: Automation, _ proposal: AutomationProposal) -> Bool {
    switch automation.definition.sink {
    case .taskCandidates:
      automation.lastFetched.contains { $0.link == proposal.item.link }
        || (automation.definition.source?.coverage == .newArrivals
          && automation.id == proposal.automationId
          && proposal.state == .open)
    case .command, .report: false
    }
  }
}

extension AutomationStore {
  /// 判定に見せる出ている候補（判定が対応済みにできる相手）。取れた項目のリンクを持つものと、新着の流れの自動化なら
  /// 自分が出して判断待ちのままのもの——新着の流れでは、対応済みの知らせが元の項目と別の項目として届くため。
  func openProposals(of id: Int, in fetched: [AutomationItem]) -> [AutomationProposal] {
    let links = Set(fetched.map(\.link))
    let streams = automation(id)?.definition.source?.coverage == .newArrivals
    return proposals.filter {
      $0.state == .open && (links.contains($0.item.link) || (streams && $0.automationId == id))
    }
  }

  /// 候補を棚に出す自動化。候補を出した自動化がまだ候補を持っていればそれ、いなければ持っている自動化のうち ID が最小のもの。
  func shelf(of proposal: AutomationProposal) -> Automation? {
    let holding = automations.filter { AutomationProposalBook.holds($0, proposal) }
    return holding.first { $0.id == proposal.automationId } ?? holding.min { $0.id < $1.id }
  }

  /// 出力先がタスク候補の他の自動化と、前回の取得結果が重なっているリンクの数（重なりのある相手だけ、ID 順）。
  func overlaps(of id: Int) -> [(automation: Automation, count: Int)] {
    guard let automation = automation(id), automation.definition.sink == .taskCandidates else {
      return []
    }
    let links = Set(automation.lastFetched.map(\.link))
    return automations.compactMap { other in
      guard other.id != id, other.definition.sink == .taskCandidates else { return nil }
      let count = links.intersection(other.lastFetched.map(\.link)).count
      return count > 0 ? (other, count) : nil
    }
  }
}
