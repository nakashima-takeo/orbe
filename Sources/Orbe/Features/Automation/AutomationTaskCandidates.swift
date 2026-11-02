import Foundation

// タスク候補の保ち方。候補は判定の出力で、出した判定のノードが持つ。同一性は（判定のノード, リンク）で、ほかの判定・ほかの自動化の
// 候補は、読みにも確定にも効かない。棚は判定のノードの持ち主の自動化。
//
// 判断待ちの候補を Orbe が下げるのは、候補が元にした行（判定が読んだ行と、その行が引き継ぎでたどる元の行）のうち項目のどれかが
// 無効になったか、元にした行がどれも出来事で判定が読んだ行が残す期間を過ぎ、判定の入力（直接の上流）の今有効な項目にも残す期間の
// 内の出来事にもそのリンクが無いときだけ。
//
// 判定のノード J の候補 P を覚えるのは、J が今のノードで役割が判定のうち、P が判断待ちの間か、P のリンクの行がまた J へ届きうる
// 間——J へ行が届くノード（入力を上流へたどり、取得で止める）の今有効な項目にリンクがあるか、J が `take: all` で読む出来事に
// リンクがある間。定義を読めない自動化は、そのノードが出した候補を持つ。読めない候補は状態が分からないので、出した判定のノードが
// 今のノードの間は覚える。

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

  /// 覚えなくなった候補（読めない候補も）を忘れる（覚えている印を外す）。
  mutating func forgetUnheld(_ db: AutomationDatabase, now: Date) throws {
    var reach: [AutomationNodeID: Set<String>] = [:]
    for automation in automations {
      for judge in automation.graph.judges {
        reach[judge.id] = Set(
          automation.graph.feeders(of: judge.id).flatMap { automation.state($0.id).liveLinks }
        ).union(try db.linksReadAgain(by: judge, now: now))
      }
    }
    let unreadableNodes = Set(unreadable.flatMap(\.nodeIds))
    func held(_ judge: AutomationNodeID, open: Bool, link: String) -> Bool {
      guard let links = reach[judge] else { return unreadableNodes.contains(judge) }
      return open || links.contains(link)
    }
    let unheld =
      proposals.filter { !held($0.judge, open: $0.state == .open, link: $0.link) }.map(\.id)
      + unreadableProposals.filter { !held($0.judge, open: true, link: $0.link) }.map(\.id)
    guard !unheld.isEmpty else { return }
    try db.forget(proposals: unheld)
    let ids = Set(unheld)
    proposals.removeAll { ids.contains($0.id) }
    unreadableProposals.removeAll { ids.contains($0.id) }
  }

  /// 項目 `items` が無効になった・ノードの今有効な項目のリンク `lost` が抜けたので、下げる条件がそろった判断待ちの候補を下げ
  /// （忘れ）、下げた数を返す。見直すのは、読んだ行が `items` から引き継ぎで降りた行の候補と、`items` を出したノードか `lost` の
  /// ノードを入力に持つ判定の、そのリンクの候補（版の更新でリンクだけが変わった項目も、前のリンクが `lost` に入る）。`now` は
  /// 変異の時刻（残す期間を過ぎた出来事も今のものでない行に数える）。
  @discardableResult mutating func withdraw(
    after items: [Int], lost: [AutomationNodeID: Set<String>] = [:], _ db: AutomationDatabase,
    now: Date
  ) throws -> Int {
    guard !items.isEmpty || lost.contains(where: { !$0.value.isEmpty }) else { return 0 }
    var candidates = try db.openProposals(descendingFrom: items)
    let linked = Dictionary(grouping: try db.linkedItems(items), by: \.nodeId)
      .mapValues { Set($0.map(\.link)) }.merging(lost) { $0.union($1) }
    for automation in automations {
      for judge in automation.graph.judges {
        let links = judge.inputNodeIds.reduce(into: Set<String>()) {
          $0.formUnion(linked[$1] ?? [])
        }
        guard !links.isEmpty else { continue }
        candidates += try db.openProposals(of: judge.id, links: links)
      }
    }
    return try withdraw(candidates, db, now: now).count
  }

  /// 判定のノード `judges` の判断待ちの候補のうち、下げる条件が既にそろった候補を下げる（忘れる）。書き換えで何をするかが変わった
  /// 判定（入力を変えた判定・直した読めない自動化の判定）に当てる。
  mutating func withdraw(
    reviewing judges: [AutomationNodeID], _ db: AutomationDatabase, now: Date
  ) throws {
    var candidates: [AutomationDatabase.OpenProposal] = []
    for judge in judges { candidates += try db.openProposals(of: judge) }
    try withdraw(candidates, db, now: now)
  }

  /// 判定が読んだ出来事が残す期間を過ぎた判断待ちの候補のうち、下げる条件がそろった候補を下げ（忘れ）、判定ごとの下げた数を
  /// 返す。回の無い契機（掃除）で下げる分。
  mutating func withdrawExpired(_ db: AutomationDatabase, now: Date) throws
    -> [AutomationNodeID: Int]
  {
    let withdrawn = try withdraw(try db.openProposals(readingEventsExpiredAt: now), db, now: now)
    return Dictionary(grouping: withdrawn, by: \.judge).mapValues(\.count)
  }

  /// 候補のうち、判定のノードが今のノードで、時刻 `now` に下げる条件がそろった候補を忘れて返す。
  @discardableResult private mutating func withdraw(
    _ candidates: [AutomationDatabase.OpenProposal], _ db: AutomationDatabase, now: Date
  ) throws -> [AutomationDatabase.OpenProposal] {
    var withdrawn: [Int: AutomationDatabase.OpenProposal] = [:]
    for candidate in candidates where withdrawn[candidate.id] == nil {
      guard
        let judge = automations.lazy.compactMap({ $0.graph.node(candidate.judge) }).first,
        judge.role == .judge,
        try db.noLongerCurrent(
          candidate.row, link: candidate.link, inputs: judge.inputNodeIds, now: now)
      else { continue }
      withdrawn[candidate.id] = candidate
    }
    guard !withdrawn.isEmpty else { return [] }
    try db.forget(proposals: Array(withdrawn.keys))
    proposals.removeAll { withdrawn[$0.id] != nil }
    unreadableProposals.removeAll { withdrawn[$0.id] != nil }
    return Array(withdrawn.values)
  }
}

extension AutomationStore {
  /// 判定のノード `judge` に見せる判断待ちの候補（判定が対応済みにできる相手）。その判定が出したものだけ。
  func openProposals(of judge: AutomationNodeID) -> [AutomationProposal] {
    proposals.filter { $0.judge == judge && $0.state == .open }
  }

  /// 候補を出した自動化——判定のノードの持ち主。定義を読めない自動化なら nil。
  func issuer(of proposal: AutomationProposal) -> Automation? {
    automations.first { $0.graph.node(proposal.judge) != nil }
  }

  /// 判定のノード `judge` の持ち主の自動化の ID（定義を読めない自動化も）。
  func issuerId(ofJudge judge: AutomationNodeID) -> Int? {
    automations.first { $0.graph.node(judge) != nil }?.id
      ?? unreadable.first { $0.nodeIds.contains(judge) }?.id
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
