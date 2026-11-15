import Foundation

// タスク候補の保ち方。候補は判定の出力で、出した判定のノードが持つ。同一性は（判定のノード, リンク）で、ほかの判定・ほかの自動化の
// 候補は、読みにも確定にも効かない。棚は判定のノードの持ち主の自動化。
//
// 候補の保ち方の 2 つの条件（下げる・覚える）は状態の決まりで、時刻付きの変異の初めと終わりに、候補すべてに当てる
// （`AutomationStore.commit`）。何が起きたかから見直す候補を選ばないので、見直す場面の並べ漏れが起きない。
//
// 判断待ちの候補を Orbe が下げるのは、候補が元にした行（判定が読んだ行と、その行が引き継ぎでたどる元の行）のうち項目のどれかが
// 無効になったか、元にした行がどれも出来事で判定が読んだ行が残す期間を過ぎ、判定の入力（直接の上流）の今の行にそのリンクが
// 無いときだけ。
//
// 判定のノード J の候補 P を覚えるのは、J が今のノードで役割が判定のうち、P が判断待ちの間か、P のリンクの行がまた J へ届きうる
// 間——J へ行が届くノード（入力を上流へたどり、取得で止める）の今有効な項目にリンクがあるか、J が `take: all` で読む出来事に
// リンクがある間——か、P を人がさばいていて、J へ行が届くノードの今の行にリンクがある間。定義を読めない自動化は、そのノードが
// 出した候補を持つ。読めない候補は状態が分からないので、出した判定のノードが今のノードの間は覚える。

extension AutomationMemory {
  /// 判定のノード `judge` の、判断待ちでない覚えている候補のリンク（読めない候補も含める。判定に見せない候補なので）。判定の前に
  /// 捨てる行はこれで言う。
  func closedLinks(of judge: AutomationNodeID) -> Set<String> {
    Set(
      proposals.filter { $0.judge == judge && $0.state != .open }.map(\.link)
        + unreadableProposals.filter { $0.judge == judge }.map(\.link))
  }

  /// 候補を覚えている判定のノードごとの `closedLinks(of:)`。
  var closedLinksByJudge: [AutomationNodeID: Set<String>] {
    let judges = Set(proposals.map(\.judge) + unreadableProposals.map(\.judge))
    return Dictionary(uniqueKeysWithValues: judges.map { ($0, closedLinks(of: $0)) })
  }

  /// 判定のノード `judge` の覚えている候補のリンク（読めない候補を含む）。確定の「既に候補がある」はこれで言う。
  func links(of judge: AutomationNodeID) -> Set<String> {
    Set(
      proposals.filter { $0.judge == judge }.map(\.link)
        + unreadableProposals.filter { $0.judge == judge }.map(\.link))
  }

  /// 今のノードで役割が判定のノード。
  private var judges: [AutomationNodeID: (graph: AutomationGraph, node: AutomationGraph.Node)] {
    Dictionary(
      uniqueKeysWithValues: automations.flatMap { automation in
        automation.graph.judges.map { ($0.id, (automation.graph, $0)) }
      })
  }

  /// 候補の保ち方の 2 つの条件を時刻 `now` に当てる: 下げる条件を満たした判断待ちの候補を下げて判定の持ち越しに数え（判定の
  /// 次の成功した回の `withdrawn`）、覚える条件から外れた候補を忘れる。
  mutating func keepProposals(_ db: AutomationDatabase, now: Date) throws {
    for (judge, count) in try withdraw(db, now: now) {
      var carried = try db.carried(of: judge)
      carried.withdrawn += count
      try db.setCarried(judge, carried)
    }
    try forgetUnheld(db, now: now)
  }

  /// 判定のノードが今のノードで役割が判定の、判断待ちの候補のうち、時刻 `now` に下げる条件を満たすものを下げ（忘れ）、判定ごとの
  /// 下げた数を返す。
  mutating func withdraw(_ db: AutomationDatabase, now: Date) throws -> [AutomationNodeID: Int] {
    let judges = self.judges
    let open = try db.openProposals().compactMap { proposal in
      judges[proposal.judge].map { (proposal, $0.node.inputNodeIds) }
    }
    guard !open.isEmpty else { return [:] }
    let gone = try db.noLongerCurrent(
      open.map { AutomationDatabase.Withdrawal(row: $0.0.row, link: $0.0.link, inputs: $0.1) },
      now: now)
    let withdrawn = zip(open, gone).filter(\.1).map(\.0.0)
    guard !withdrawn.isEmpty else { return [:] }
    try db.forget(proposals: withdrawn.map(\.id))
    let ids = Set(withdrawn.map(\.id))
    proposals.removeAll { ids.contains($0.id) }
    unreadableProposals.removeAll { ids.contains($0.id) }
    return Dictionary(grouping: withdrawn, by: \.judge).mapValues(\.count)
  }

  /// 時刻 `now` に覚える条件から外れた候補（読めない候補も）を忘れる（覚えている印を外す）。
  mutating func forgetUnheld(_ db: AutomationDatabase, now: Date) throws {
    let judges = self.judges
    let settled = proposals.filter { $0.state != .open && judges[$0.judge] != nil }
    /// 判定ごとの、また届きうるリンク（判定が対応済みにした候補を覚える分）と、人がさばいた候補を覚える分。
    var reach: [AutomationNodeID: (again: Set<String>, rows: Set<String>)] = [:]
    if !settled.isEmpty {
      var feeders: [AutomationNodeID: [AutomationNodeID]] = [:]
      for judge in Set(settled.map(\.judge)) {
        guard let (graph, _) = judges[judge] else { continue }
        feeders[judge] = graph.feeders(of: judge).map(\.id)
      }
      let current = try db.currentLinks(
        of: Set(feeders.values.joined()), among: Set(settled.map(\.link)), now: now)
      for (judge, nodes) in feeders {
        guard let (_, node) = judges[judge] else { continue }
        let again = try nodes.reduce(into: db.linksReadAgain(by: node, now: now)) {
          $0.formUnion(current.items[$1] ?? [])
        }
        reach[judge] = (again, nodes.reduce(into: again) { $0.formUnion(current.events[$1] ?? []) })
      }
    }
    let unreadableNodes = Set(unreadable.flatMap(\.nodeIds))
    func held(_ proposal: AutomationProposal) -> Bool {
      guard judges[proposal.judge] != nil else { return unreadableNodes.contains(proposal.judge) }
      switch proposal.state {
      case .open: return true
      case .resolved: return reach[proposal.judge]?.again.contains(proposal.link) == true
      case .accepted, .dismissed: return reach[proposal.judge]?.rows.contains(proposal.link) == true
      }
    }
    let unheld =
      proposals.filter { !held($0) }.map(\.id)
      + unreadableProposals.filter {
        judges[$0.judge] == nil && !unreadableNodes.contains($0.judge)
      }.map(\.id)
    guard !unheld.isEmpty else { return }
    try db.forget(proposals: unheld)
    let ids = Set(unheld)
    proposals.removeAll { ids.contains($0.id) }
    unreadableProposals.removeAll { ids.contains($0.id) }
  }
}

extension AutomationStore {
  /// 判定のノード `judge` に見せる判断待ちの候補（判定が対応済みにできる相手）。その判定が出したものだけ。
  func openProposals(of judge: AutomationNodeID) -> [AutomationProposal] {
    proposals.filter { $0.judge == judge && $0.state == .open }
  }

  /// 候補を出した自動化——判定のノードの持ち主。定義を読めない自動化なら nil。
  func issuer(of proposal: AutomationProposal) -> Automation? {
    issuer(ofJudge: proposal.judge)
  }

  /// 判定のノード `judge` の持ち主の自動化。定義を読めない自動化なら nil。
  func issuer(ofJudge judge: AutomationNodeID) -> Automation? {
    automations.first { $0.graph.node(judge) != nil }
  }

  /// 判断待ちの候補と、それを棚に出す自動化（候補を出した自動化）の ID（候補の順）。定義を読めない自動化の候補は入らない。
  /// ⌘⇧X の提案タブ・制御 API・ボードはどれもここから数える——棚の規則を変えたとき、数え方が読み手ごとにずれないため。
  var shelvedProposals: [(proposal: AutomationProposal, shelf: Int)] {
    proposals.compactMap { proposal in
      guard proposal.state == .open, let issuer = issuer(of: proposal) else { return nil }
      return (proposal, issuer.id)
    }
  }

  /// `id` の自動化の棚に出ている判断待ちの候補。
  func shelvedProposals(of id: Int) -> [AutomationProposal] {
    shelvedProposals.filter { $0.shelf == id }.map(\.proposal)
  }

  /// 判定のノードの今の定義が出した候補への人の判断の数（判断の記録の内。数は持たず、読むたびに数える）。
  func settlementCounts(of judge: AutomationGraph.Node) throws(AutomationError)
    -> (accepted: Int, dismissed: Int)
  {
    try read { try $0.settlementCounts(of: judge.id, defId: judge.entity.defId) }
  }
}

/// 判定の出力から読み取った 1 つの決定。`workspace` は照合を済ませた付け先の `Workspace.id`。
enum AutomationDecision: Equatable {
  case propose(
    itemId: String, title: String, due: TaskItem.DueDate?, workspace: UUID?, reason: String?)
  case resolve(link: String)
}

/// 判定に見せ、判定の出力をその中で照合する選択肢。1 回の中で起こす前に 1 度だけ取り、依頼文と読み取りの両方に同じ値を
/// 使う——回の途中に候補がさばかれたり workspace が増減・改名されたりしても、判定が見たものと照合するものが食い違わない。
struct AutomationJudgeChoices: Equatable {
  /// 判断待ちの候補（resolve の相手）。
  let open: [AutomationProposal]
  let workspaces: AutomationWorkspaces
}
