import Foundation

/// 一巡——ノードを指して「そこまで流す」1 回の進み。道（流すノードの集まり。一巡の間は変わらない）の上で、普段なら今すぐは
/// 動かないノード（入力の無いノード、間隔・cron・手動の入力のあるノード、実効で止めたノード）を、道の上の上流がすべて終わった後に
/// 1 回ずつ起こし、指したノードがすべて終わったら終わる。実効で止めていない「届いたら」のノードは起こさず、普段の決まりで動いた後の
/// 終わりを見届ける。各ノードが待つのは道の上の入力だけで、道の上の入力を持たないノード（道の根）は予定の種類によらず最初に起こす。
/// 本番の流しは道を「指したノードとその祖先すべて」にするので、根は入力の無いノードだけになる。
///
/// 走らせ役がメモリに持ち、ノードの契機の始まりと終わり（普段の起こす決まりを見た後）を今の自動化と共に知らせる。返したノードは
/// 走らせ役が「今すぐ」で起こす。起こすか見届けるかは知らせのたびに今の予定の種類と止めているかで決める——一巡の間に予定だけを
/// 書き換えたり、ノードを止めたり再開したりしても一巡は続くので、流し始めの状態で決めると今とずれる（止めた「届いたら」のノードを
/// 動かさないまま一巡を終える）。道の形（入力・行き先）が変わる書き換えはノードを番人から外すので、一巡はそこで打ち切られる。
struct AutomationFlow {
  enum Target: Equatable {
    case node(AutomationNodeID)
    /// 終わりのノードすべて（`AutomationGraph.ends`）。
    case ends
    /// タスク候補を行き先にするノードすべて（`AutomationGraph.judges`）。
    case judges
  }

  private enum Step: Equatable {
    /// 道の上の上流で、まだ終わっていないもの。
    case waiting(Set<AutomationNodeID>)
    /// 道の上の上流がすべて終わった。見届けるノードなら走っていなければ終わり、そうでなければ次に始まる契機を一巡の分として
    /// 受け取る（走っていなければ起こす）。実効で止めた根でない「届いたら」のノードは、回の終わりに基準線より新しい上流の行が
    /// 無ければ、その回を一巡の分に数えて終わる。
    case ready
    /// 流し始めに走っていた入力の無いノードの回を一巡の分にした。次の終わりがその回のもの。
    case adopted
    /// 一巡の分として受け取った契機が走っている。一巡の分の契機の終わりだけを数える。
    case taken
    case done
  }

  private let targets: [AutomationNodeID]
  /// 道の根。
  private let roots: Set<AutomationNodeID>
  private var steps: [AutomationNodeID: Step] = [:]

  /// `path` の上を `targets`（どれも `path` の上）まで流し始める。`wake` は今すぐ起こすノード（走っていない根）。入力の無い根が
  /// 走っていれば、その回を一巡の分にする（入力が無いので、いつ始まった回でも出すものは同じ）。入力のある根が走っていれば、
  /// その回が終わった後に起こす。
  static func start(
    through path: Set<AutomationNodeID>, to targets: [AutomationNodeID],
    in automation: Automation, running: (AutomationNodeID) -> Bool
  ) -> (flow: AutomationFlow, wake: [AutomationNodeID]) {
    let nodes = automation.graph.nodes.filter { path.contains($0.id) }
    var flow = AutomationFlow(
      targets: targets,
      roots: Set(nodes.filter { path.isDisjoint(with: $0.inputNodeIds) }.map(\.id)))
    var wake: [AutomationNodeID] = []
    for node in nodes {
      let upstream = path.intersection(node.inputNodeIds)
      if !upstream.isEmpty {
        flow.steps[node.id] = .waiting(upstream)
      } else if node.inputs.isEmpty && running(node.id) {
        flow.steps[node.id] = .adopted
      } else {
        flow.steps[node.id] = .ready
        if !running(node.id) { wake.append(node.id) }
      }
    }
    return (flow, wake)
  }

  private init(targets: [AutomationNodeID], roots: Set<AutomationNodeID>) {
    self.targets = targets
    self.roots = roots
  }

  var path: Set<AutomationNodeID> { Set(steps.keys) }

  var finished: Bool { targets.allSatisfy { steps[$0] == .done } }

  /// ノードが一巡の分を終えたか。
  func isDone(_ nodeId: AutomationNodeID) -> Bool { steps[nodeId] == .done }

  /// ノードの契機が始まった。一巡の分として受け取ったら真（走らせ役はその契機を `flowed` として覚え、終わりに渡す）。誰が
  /// 始めた回かは問わない。
  mutating func started(_ nodeId: AutomationNodeID, in automation: Automation) -> Bool {
    guard steps[nodeId] == .ready, !watched(nodeId, in: automation) else { return false }
    steps[nodeId] = .taken
    return true
  }

  /// ノードの契機が終わった（`flowed` は一巡の分として受け取った契機か、`covered` は終わりの時点で、その契機の基準線より新しい
  /// 上流の行が無いか）。返すのは今すぐ起こすノード。受け取ったノードは一巡の分の契機の終わりだけを数える——番人は回の終わりの
  /// 中で次の予定の回を同期に始めうるので、古い回の終わりが受け取った回の始まりより後に届く。一巡の分でない回の終わりは、起こす
  /// ノードを邪魔していた回が終わったとして、走っていなければ起こし直す。ただし実効で止めた根でない「届いたら」のノードは、
  /// `covered` ならその回を一巡の分に数える——普段の起こす決まりと同じく、読んだ行で起こし直さない（失敗した回の行も読み直さない）。
  mutating func ended(
    _ nodeId: AutomationNodeID, flowed: Bool, covered: Bool, in automation: Automation,
    running: (AutomationNodeID) -> Bool
  ) -> [AutomationNodeID] {
    switch steps[nodeId] {
    case .adopted:
      return finish(nodeId, automation, running)
    case .taken where flowed:
      return finish(nodeId, automation, running)
    case .ready where covered && nonRootArrival(nodeId, in: automation):
      return finish(nodeId, automation, running)
    case .ready:
      return advance(nodeId, automation, running)
    default:
      return []
    }
  }

  /// ノードを終わりにし、道の上の上流がすべて終わった下流を次へ進める。
  private mutating func finish(
    _ nodeId: AutomationNodeID, _ automation: Automation, _ running: (AutomationNodeID) -> Bool
  ) -> [AutomationNodeID] {
    steps[nodeId] = .done
    var wake: [AutomationNodeID] = []
    for node in automation.graph.downstream(of: nodeId) {
      guard case .waiting(var upstream) = steps[node.id] else { continue }
      upstream.remove(nodeId)
      guard upstream.isEmpty else {
        steps[node.id] = .waiting(upstream)
        continue
      }
      steps[node.id] = .ready
      wake += advance(node.id, automation, running)
    }
    return wake
  }

  /// 上流がすべて終わったノードを、走っていなければ進める——見届けるノードなら終わりにし、そうでなければ起こす。
  private mutating func advance(
    _ nodeId: AutomationNodeID, _ automation: Automation, _ running: (AutomationNodeID) -> Bool
  ) -> [AutomationNodeID] {
    guard !running(nodeId) else { return [] }
    return watched(nodeId, in: automation) ? finish(nodeId, automation, running) : [nodeId]
  }

  /// 普段の決まりで起きるのを見届けるノードか（根でない、実効で止めていない「届いたら」のノード）。
  private func watched(_ nodeId: AutomationNodeID, in automation: Automation) -> Bool {
    guard let node = automation.graph.node(nodeId) else { return false }
    return Self.watches(node, roots: roots, in: automation)
  }

  /// 道の根が `roots` である一巡が、ノードを普段の決まりで起きるのを見届けるか（根でない、実効で止めていない「届いたら」のノード）。
  static func watches(
    _ node: AutomationGraph.Node, roots: Set<AutomationNodeID>, in automation: Automation
  ) -> Bool {
    !roots.contains(node.id) && node.entity.trigger == .arrival && !automation.halted(node.id)
  }

  /// 根でない「届いたら」のノードか（止めているかは問わない）。
  private func nonRootArrival(_ nodeId: AutomationNodeID, in automation: Automation) -> Bool {
    !roots.contains(nodeId) && automation.graph.node(nodeId)?.entity.trigger == .arrival
  }
}
