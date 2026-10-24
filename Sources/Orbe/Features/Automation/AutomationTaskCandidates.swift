import Foundation

// タスク候補の保ち方。候補はリンク単位で、覚えている候補を通じて 1 つ。判断待ちの候補を Orbe が下げるのは、出どころが今の集合の
// 項目で、その項目が無効になったときだけ（出来事が出どころの候補は自動では下げない）。候補は、どの自動化も持たなくなったときに
// 忘れ、それまでは同じリンクを再び候補にしない。
//
// 自動化 A がリンク L の候補を持つのは、A のタスク候補へ至る取得のノードのどれかの今有効な項目に L があるとき、または A の判定の
// ノードが出して判断待ちのとき。止めた自動化も持つ。定義を読めない自動化は、そのノードが出した候補と、そのノードが出どころの候補を
// 持つ。読めない候補は状態が分からないので、出した判定のノードがある間は、そのノードの自動化が持つ。

extension Automation {
  /// タスク候補へ至る取得のノードの今有効な項目のリンク。持ち主・重なりはこの集合で言う。
  var candidateLinks: Set<String> {
    Set(
      graph.nodes.filter { $0.role == .fetch && graph.reachesTaskCandidates($0.id) }
        .flatMap { state($0.id).liveLinks })
  }

  /// この自動化が候補を持っているか。
  func holds(_ proposal: AutomationProposal) -> Bool {
    candidateLinks.contains(proposal.item.link)
      || (proposal.state == .open && graph.node(proposal.judge)?.role == .judge)
  }

  func holds(_ proposal: AutomationUnreadableProposal) -> Bool {
    candidateLinks.contains(proposal.link) || graph.node(proposal.judge) != nil
  }
}

extension AutomationUnreadable {
  func holds(_ proposal: AutomationProposal) -> Bool {
    nodeIds.contains(proposal.judge) || nodeIds.contains(proposal.originNodeId)
  }

  func holds(_ proposal: AutomationUnreadableProposal) -> Bool {
    nodeIds.contains(proposal.judge)
  }
}

extension AutomationMemory {
  /// どの自動化も持たない候補（読めない候補も）を忘れる（覚えている印を外す）。
  mutating func forgetUnheld(_ db: AutomationDatabase) throws {
    let automations = automations
    let unreadable = unreadable
    let unheld =
      proposals.filter { proposal in
        !automations.contains { $0.holds(proposal) } && !unreadable.contains { $0.holds(proposal) }
      }.map(\.id)
      + unreadableProposals.filter { proposal in
        !automations.contains { $0.holds(proposal) } && !unreadable.contains { $0.holds(proposal) }
      }.map(\.id)
    guard !unheld.isEmpty else { return }
    try db.forget(proposals: unheld)
    let ids = Set(unheld)
    proposals.removeAll { ids.contains($0.id) }
    unreadableProposals.removeAll { ids.contains($0.id) }
  }

  /// 出どころの項目が無効になった判断待ちの候補を下げ（忘れ）、下げた数を返す。
  @discardableResult mutating func withdraw(originatingIn items: [Int], _ db: AutomationDatabase)
    throws -> Int
  {
    let ids = Set(try db.openProposals(originatingIn: items))
    guard !ids.isEmpty else { return 0 }
    try db.forget(proposals: Array(ids))
    let withdrawn = proposals.filter { ids.contains($0.id) && $0.state == .open }.count
    proposals.removeAll { ids.contains($0.id) }
    unreadableProposals.removeAll { ids.contains($0.id) }
    return withdrawn
  }
}

extension AutomationStore {
  /// 判定のノード `judge` に見せる判断待ちの候補（判定が対応済みにできる相手）。その判定へ行が届く取得のノードの今有効な項目に
  /// リンクがあるものと、その判定が出したもの・その取得のノードが出どころのもの。
  func openProposals(of id: Int, judge: AutomationNodeID) -> [AutomationProposal] {
    guard let automation = automation(id) else { return [] }
    let fetches = automation.graph.fetches(reaching: judge)
    let links = Set(fetches.flatMap { automation.state($0.id).liveLinks })
    let originNodeIds = Set(fetches.map(\.id))
    return proposals.filter {
      $0.state == .open
        && (links.contains($0.item.link) || $0.judge == judge
          || originNodeIds.contains($0.originNodeId))
    }
  }

  /// 候補を出した自動化——判定のノードの持ち主（ノードを外しても自動化が残れば、その自動化）。持ち主を消していれば nil。
  func issuer(of proposal: AutomationProposal) -> Automation? {
    judgeOwners[proposal.judge].flatMap(automation)
  }

  /// 候補を棚に出す自動化。候補を出した自動化がまだ候補を持っていればそれ、いなければ持っている自動化のうち ID が最小のもの。
  func shelf(of proposal: AutomationProposal) -> Automation? {
    let holding = automations.filter { $0.holds(proposal) }
    let issuer = issuer(of: proposal)?.id
    return holding.first { $0.id == issuer } ?? holding.min { $0.id < $1.id }
  }

  /// 読めない候補を持つ自動化（棚の規則と同じく、出した自動化が持っていればそれ、いなければ ID が最小のもの）。棚には出さず、
  /// 外の口の絞り込みにだけ使う。
  func holder(of proposal: AutomationUnreadableProposal) -> Automation? {
    let holding = automations.filter { $0.holds(proposal) }
    let issuer = judgeOwners[proposal.judge]
    return holding.first { $0.id == issuer } ?? holding.min { $0.id < $1.id }
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

  /// 判定のノードを持つ他の自動化と、タスク候補へ至る取得のノードの今有効な項目が重なっているリンクの数（重なりのある相手だけ、
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
