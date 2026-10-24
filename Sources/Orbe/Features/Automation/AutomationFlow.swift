import Foundation

/// 一巡——部品を指して「そこまで流す」1 回の進み。道（流す部品の集まり。一巡の間は変わらない）の上で、普段なら今すぐは
/// 動かない部品（入力の無い部品と、間隔・cron・手動の入力のある部品）を、道の上の上流がすべて終わった後に 1 回ずつ起こし、
/// 指した部品がすべて終わったら終わる。「届いたら」の部品は起こさず、普段の決まりで動いた後の終わりを見届ける。各部品が待つのは
/// 道の上の入力だけで、道の上の入力を持たない部品（道の根）は予定の種類によらず最初に起こす。本番の流しは道を「指した部品と
/// その祖先すべて」にするので、根は入力の無い部品だけになる。
///
/// 走らせ役がメモリに持ち、部品の契機の始まりと終わり（普段の起こす決まりを見た後）を今の定義と共に知らせる。返した部品は
/// 走らせ役が「今すぐ」で起こす。起こすか見届けるかは知らせのたびに今の定義の予定の種類で決める——一巡の間に予定だけを
/// 書き換えても一巡は続くので、流し始めの定義で決めると今の予定とずれる。道の形（入力・行き先）が変わる書き換えは部品を
/// 番人から外すので、一巡はそこで打ち切られる。
struct AutomationFlow {
  enum Target: Equatable {
    case part(AutomationNodeID)
    /// 終わりの部品すべて（`AutomationGraph.ends`）。
    case ends
    /// タスク候補を行き先にする部品すべて（`AutomationGraph.judges`）。
    case judges
  }

  private enum Step: Equatable {
    /// 道の上の上流で、まだ終わっていないもの。
    case waiting(Set<AutomationNodeID>)
    /// 道の上の上流がすべて終わった。「届いたら」なら走っていなければ終わり、そうでなければ次に始まる契機を一巡の分として
    /// 受け取る（走っていなければ起こす）。
    case ready
    /// 流し始めに走っていた入力の無い部品の回を一巡の分にした。次の終わりがその回のもの。
    case adopted
    /// 一巡の分として受け取った契機が走っている。一巡の分の契機の終わりだけを数える。
    case taken
    case done
  }

  private let targets: [AutomationNodeID]
  /// 道の根。
  private let roots: Set<AutomationNodeID>
  private var steps: [AutomationNodeID: Step] = [:]

  /// `path` の上を `targets`（どれも `path` の上）まで流し始める。`wake` は今すぐ起こす部品（走っていない根）。入力の無い根が
  /// 走っていれば、その回を一巡の分にする（入力が無いので、いつ始まった回でも出すものは同じ）。入力のある根が走っていれば、
  /// その回が終わった後に起こす。
  static func start(
    through path: Set<AutomationNodeID>, to targets: [AutomationNodeID], in graph: AutomationGraph,
    running: (AutomationNodeID) -> Bool
  ) -> (flow: AutomationFlow, wake: [AutomationNodeID]) {
    let nodes = graph.nodes.filter { path.contains($0.id) }
    var flow = AutomationFlow(
      targets: targets,
      roots: Set(nodes.filter { path.isDisjoint(with: $0.inputParts) }.map(\.id)))
    var wake: [AutomationNodeID] = []
    for node in nodes {
      let upstream = path.intersection(node.inputParts)
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

  /// 部品が一巡の分を終えたか。
  func isDone(_ part: AutomationNodeID) -> Bool { steps[part] == .done }

  /// 部品の契機が始まった。一巡の分として受け取ったら真（走らせ役はその契機を `flowed` として覚え、終わりに渡す）。誰が
  /// 始めた回かは問わない。
  mutating func started(_ part: AutomationNodeID, in graph: AutomationGraph) -> Bool {
    guard steps[part] == .ready, !arrives(part, in: graph) else { return false }
    steps[part] = .taken
    return true
  }

  /// 部品の契機が終わった（`flowed` は一巡の分として受け取った契機か）。返すのは今すぐ起こす部品。受け取った部品は一巡の分の
  /// 契機の終わりだけを数える——番人は回の終わりの中で次の予定の回を同期に始めうるので、古い回の終わりが受け取った回の始まり
  /// より後に届く。一巡の分でない回の終わりは、起こす部品を邪魔していた回が終わったとして、走っていなければ起こし直す。
  mutating func ended(
    _ part: AutomationNodeID, flowed: Bool, in graph: AutomationGraph,
    running: (AutomationNodeID) -> Bool
  ) -> [AutomationNodeID] {
    switch steps[part] {
    case .adopted:
      return finish(part, graph, running)
    case .taken where flowed:
      return finish(part, graph, running)
    case .ready:
      return settle(part, graph, running)
    default:
      return []
    }
  }

  /// 部品を終わりにし、道の上の上流がすべて終わった下流を次へ進める。
  private mutating func finish(
    _ part: AutomationNodeID, _ graph: AutomationGraph, _ running: (AutomationNodeID) -> Bool
  ) -> [AutomationNodeID] {
    steps[part] = .done
    var wake: [AutomationNodeID] = []
    for node in graph.downstream(of: part) {
      guard case .waiting(var upstream) = steps[node.id] else { continue }
      upstream.remove(part)
      guard upstream.isEmpty else {
        steps[node.id] = .waiting(upstream)
        continue
      }
      steps[node.id] = .ready
      wake += settle(node.id, graph, running)
    }
    return wake
  }

  /// 上流がすべて終わった部品を、走っていなければ進める——「届いたら」なら終わりにし、そうでなければ起こす。
  private mutating func settle(
    _ part: AutomationNodeID, _ graph: AutomationGraph, _ running: (AutomationNodeID) -> Bool
  ) -> [AutomationNodeID] {
    guard !running(part) else { return [] }
    return arrives(part, in: graph) ? finish(part, graph, running) : [part]
  }

  /// 普段の決まりで起きるのを見届ける部品か（根でない「届いたら」の部品）。
  private func arrives(_ part: AutomationNodeID, in graph: AutomationGraph) -> Bool {
    !roots.contains(part) && graph.node(part)?.entity.trigger == .arrival
  }
}
