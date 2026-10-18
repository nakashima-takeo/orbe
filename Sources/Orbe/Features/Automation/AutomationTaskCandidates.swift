import Foundation

// タスク候補の保ち方。候補はリンク単位で全自動化を通じて 1 つ。候補が忘れられるのは、どの自動化も候補を持たなくなったとき
// だけで、それまではタスクにした・捨てた・対応済みの候補も覚えていて、同じリンクを再び候補にしない。
//
// 自動化 A がリンク L の候補を持つのは、A のタスク候補へ至る取得の部品のどれかの前回の出力に L があるとき、または A の判定の
// 部品が出して判断待ちで、出どころの取得の部品が今の A のグラフで新着の流れのとき。止めた自動化も持つ。

extension Automation {
  /// タスク候補へ至る取得の部品の前回の出力のリンク。持ち主・重なりはこの集合で言う。
  var candidateLinks: Set<String> {
    Set(
      graph.nodes.filter { node in
        if case .fetch = node.role { return graph.reachesTaskCandidates(node.key) }
        return false
      }.flatMap { state($0.key).lastOutput.map(\.link) })
  }

  /// この自動化が候補を持っているか。
  func holds(_ proposal: AutomationProposal) -> Bool {
    candidateLinks.contains(proposal.item.link) || streams(proposal)
  }

  /// この自動化の判定の部品が出して判断待ちで、出どころの取得の部品が今のグラフで新着の流れか——新着の流れでは、対応済みの
  /// 知らせが元の項目と別の項目として届くため、取得から消えても持ち続ける。
  func streams(_ proposal: AutomationProposal) -> Bool {
    proposal.automationId == id && proposal.state == .open
      && graph.node(proposal.partKey)?.role == .judge
      && graph.node(proposal.sourcePartKey)?.role == .fetch(.newArrivals)
  }
}

extension AutomationMemory {
  /// どの自動化も持たない候補を忘れ（DB からも消す）、そのうち判断待ちだったもの（下げた候補）の数を返す。
  @discardableResult mutating func forgetUnheld(_ db: AutomationDatabase) throws -> Int {
    let automations = automations
    let unheld = proposals.filter { proposal in !automations.contains { $0.holds(proposal) } }
    guard !unheld.isEmpty else { return 0 }
    try db.delete(proposals: unheld.map(\.id))
    let ids = Set(unheld.map(\.id))
    proposals.removeAll { ids.contains($0.id) }
    return unheld.filter { $0.state == .open }.count
  }
}

extension AutomationStore {
  /// 判定の部品 `judge` に見せる判断待ちの候補（判定が対応済みにできる相手）。その判定へ行が届く取得の部品の前回の出力に
  /// リンクがあるものと、その判定が出して判断待ちのままの新着の流れのもの。
  func openProposals(of id: Int, judge: String) -> [AutomationProposal] {
    guard let automation = automation(id) else { return [] }
    let links = Set(
      automation.graph.fetches(reaching: judge).flatMap {
        automation.state($0.key).lastOutput.map(\.link)
      })
    return proposals.filter {
      $0.state == .open
        && (links.contains($0.item.link) || ($0.partKey == judge && automation.streams($0)))
    }
  }

  /// 候補を棚に出す自動化。候補を出した自動化がまだ候補を持っていればそれ、いなければ持っている自動化のうち ID が最小のもの。
  func shelf(of proposal: AutomationProposal) -> Automation? {
    let holding = automations.filter { $0.holds(proposal) }
    return holding.first { $0.id == proposal.automationId } ?? holding.min { $0.id < $1.id }
  }

  /// 判断待ちの候補と、それを棚に出す自動化の ID（候補の順）。棚に出す自動化の無い候補は入らない。⌘⇧X の提案タブ・制御 API・
  /// ボードはどれもここから数える——棚の規則を変えたとき、数え方が読み手ごとにずれないため。
  var shelvedProposals: [(proposal: AutomationProposal, shelf: Int)] {
    proposals.compactMap { proposal in
      guard proposal.state == .open, let shelf = shelf(of: proposal) else { return nil }
      return (proposal, shelf.id)
    }
  }

  /// `id` の自動化の棚に出ている判断待ちの候補。
  func shelvedProposals(of id: Int) -> [AutomationProposal] {
    shelvedProposals.filter { $0.shelf == id }.map(\.proposal)
  }

  /// 判定の部品を持つ他の自動化と、タスク候補へ至る取得の部品の前回の出力が重なっているリンクの数（重なりのある相手だけ、
  /// ID 順）。
  func overlaps(of id: Int) -> [(automation: Automation, count: Int)] {
    guard let automation = automation(id), automation.judges else { return [] }
    let links = automation.candidateLinks
    return automations.compactMap { other in
      guard other.id != id, other.judges else { return nil }
      let count = links.intersection(other.candidateLinks).count
      return count > 0 ? (other, count) : nil
    }
  }
}

/// 判定の出力から読み取った 1 つの決定。`workspace` は照合を済ませた付け先の `Workspace.persistentId`。
enum AutomationDecision: Equatable {
  case propose(itemId: String, title: String, due: TaskItem.DueDate?, workspace: UUID?)
  case resolve(link: String)
}

/// 判定に見せ、判定の出力をその中で照合する選択肢。1 回の中で起こす前に 1 度だけ取り、依頼文と読み取りの両方に同じ値を
/// 使う——回の途中に候補がさばかれたり workspace が増減・改名されたりしても、判定が見たものと照合するものが食い違わない。
struct AutomationJudgeChoices: Equatable {
  /// 判断待ちの候補（resolve の相手）。
  let open: [AutomationProposal]
  let workspaces: AutomationWorkspaces
}

/// 候補の付け先にできる workspace。
struct AutomationWorkspaces: Equatable {
  /// 判定に見せる workspace（Home を除く。サイドバーの順）。
  let listed: [AutomationWorkspace]
  /// Home の起動ごとの ID。付け先にこれを書いた行は付け先なし（Home に付く）として受ける——コマンドの判定は
  /// `orb ws list --json` から Home の ID を書きうる。
  let home: Int?
}

/// 判定に付け先として見せる workspace 1 つ。`id` は起動ごとの ID で、1 回の中でしか使わず保存しない。
struct AutomationWorkspace: Equatable {
  let id: Int
  let persistentId: UUID
  let name: String
  let root: String
}
