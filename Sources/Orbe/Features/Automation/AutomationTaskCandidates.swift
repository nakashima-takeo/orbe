import Foundation

// タスク候補の保ち方。候補は判定の出力で、出した判定のノードが持つ。同一性は（判定のノード, リンク）で、ほかの判定・ほかの自動化の
// 候補は、読みにも確定にも効かない。棚は判定のノードの持ち主の自動化。
//
// 候補を覚えるのは、出した判定のノードが今のノードで役割が判定である間、かつ候補が下げる条件を満たすまで（状態によらない。候補は元にした
// 行を指す印なので、長さは元にした行の保存の規則に従う）。状態は判定に行を渡すかどうかだけを変える（`closedLinks(of:)`）。条件は状態の
// 決まりで、時刻付きの変異の初めと終わりに、覚えている候補すべてに当てる（`AutomationStore.commit`）。何が起きたかをもとに見直す候補を
// 選ばないので、見直す場面の並べ漏れが起きない。
//
// 下げる条件は、(a) か (b) のどちらかを満たし、かつ (c) を満たすこと。(a) 候補が元にした行（判定が読んだ行と、その行が
// 引き継ぎでたどる元の行）のうち項目のどれかが無効になった。(b) 元にした行がどれも出来事で、判定が読んだ行が残す期間を過ぎた。
// (c) 判定の入力（直接の上流）の今の行にそのリンクが無い。満たした判断待ちの候補は下げ（数える）、判断待ちでない候補は数えずに忘れる。定義を読めない自動化は、その
// ノードが出した候補を持つ。読めない候補は状態が分からないので、出した判定のノードが今のノードの間は覚える。

extension AutomationMemory {
  /// 判定のノード `judge` の、判断待ちでない覚えている候補のリンク。判定の前に捨てる行はこれで表す。
  func closedLinks(of judge: AutomationNodeID) -> AutomationIntake.Closed {
    var closed = AutomationIntake.Closed()
    for proposal in proposals where proposal.judge == judge {
      switch proposal.state {
      case .open: break
      case .accepted, .dismissed: closed.settled.insert(proposal.link)
      case .resolved: closed.resolved.insert(proposal.link)
      }
    }
    for proposal in unreadableProposals where proposal.judge == judge {
      closed.settled.insert(proposal.link)
    }
    return closed
  }

  /// 候補を覚えている判定のノードごとの `closedLinks(of:)`。
  var closedLinksByJudge: [AutomationNodeID: AutomationIntake.Closed] {
    let judges = Set(proposals.map(\.judge) + unreadableProposals.map(\.judge))
    return Dictionary(uniqueKeysWithValues: judges.map { ($0, closedLinks(of: $0)) })
  }

  /// 判定のノード `judge` の、対応済みでない覚えている候補のリンク（読めない候補を含む）。確定の「既に候補がある」はこれで
  /// 表す。対応済みの候補のリンクの案は、その候補を置き換える。
  func links(of judge: AutomationNodeID) -> Set<String> {
    Set(
      proposals.filter { $0.judge == judge && $0.state != .resolved }.map(\.link)
        + unreadableProposals.filter { $0.judge == judge }.map(\.link))
  }

  /// 今のノードで役割が判定のノード。
  private var judges: [AutomationNodeID: AutomationGraph.Node] {
    Dictionary(
      uniqueKeysWithValues: automations.flatMap { $0.graph.judges.map { ($0.id, $0) } })
  }

  /// 候補を保つ決まりを時刻 `now` に当てる: 下げる条件を満たした判断待ちの候補を下げて判定の持ち越しに数え（判定の次の成功した
  /// 回の `withdrawn`）、満たした判断待ちでない候補と、判定のノードが今のノードでない候補を忘れる。
  mutating func keepProposals(_ db: AutomationDatabase, now: Date) throws {
    for (judge, count) in try withdraw(db, now: now) {
      var carried = try db.carried(of: judge)
      carried.withdrawn += count
      try db.setCarried(judge, carried)
    }
    try forgetUnheld(db)
  }

  /// 覚えている候補のうち、判定のノードが今のノードで役割が判定であり、時刻 `now` に下げる条件を満たすものを忘れる。判断待ちの候補は
  /// 下げたとして判定ごとに数えて返し、判断待ちでない候補（人がさばいた・対応済み）は数えない。読めない候補には、判断待ちのときだけ
  /// 下げる条件を当てる（状態が分からないので）。
  mutating func withdraw(_ db: AutomationDatabase, now: Date) throws -> [AutomationNodeID: Int] {
    let judges = self.judges
    let readable = Set(proposals.map(\.id))
    let held = try db.heldProposals().compactMap { proposal in
      judges[proposal.judge].flatMap { judge in
        proposal.open || readable.contains(proposal.id) ? (proposal, judge.inputNodeIds) : nil
      }
    }
    guard !held.isEmpty else { return [:] }
    let gone = try db.noLongerCurrent(
      held.map { AutomationDatabase.Withdrawal(row: $0.0.row, link: $0.0.link, inputs: $0.1) },
      now: now)
    let forgotten = zip(held, gone).filter(\.1).map(\.0.0)
    guard !forgotten.isEmpty else { return [:] }
    try db.forget(proposals: forgotten.map(\.id))
    let ids = Set(forgotten.map(\.id))
    proposals.removeAll { ids.contains($0.id) }
    unreadableProposals.removeAll { ids.contains($0.id) }
    return Dictionary(grouping: forgotten.filter(\.open), by: \.judge).mapValues(\.count)
  }

  /// 覚えている候補（読めない候補も）のうち、判定のノードが今のノードでないか役割が判定でないものを忘れる。定義を読めない自動化のノードが出した候補は覚える。
  private mutating func forgetUnheld(_ db: AutomationDatabase) throws {
    let judges = self.judges
    let unreadableNodes = Set(unreadable.flatMap(\.nodeIds))
    func held(_ judge: AutomationNodeID) -> Bool {
      judges[judge] != nil || unreadableNodes.contains(judge)
    }
    let unheld =
      proposals.filter { !held($0.judge) }.map(\.id)
      + unreadableProposals.filter { !held($0.judge) }.map(\.id)
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

/// 判定に見せ、判定の出力をその中で照合する選択肢。1 回の中で判定を実行する前に 1 度だけ取り、依頼文と読み取りの両方に同じ値を
/// 使う——回の途中に候補がさばかれたり workspace が増減・改名されたりしても、判定が見たものと照合するものが食い違わない。
struct AutomationJudgeChoices: Equatable {
  /// 判断待ちの候補（resolve の相手）。
  let open: [AutomationProposal]
  let workspaces: AutomationWorkspaces
}
