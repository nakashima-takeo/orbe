import Foundation

/// 一巡——部品を指して「そこまで流す」1 回の進み。道（指した部品とその祖先。一巡の間は変わらない）の上で、普段なら今すぐは
/// 動かない部品（入力の無い部品と、間隔・cron・手動の入力のある部品）を、道の上の上流がすべて終わった後に 1 回ずつ起こし、
/// 指した部品がすべて終わったら終わる。「届いたら」の部品は起こさず、普段の決まりで動いた後の終わりを見届ける。
///
/// 走らせ役がメモリに持ち、部品の契機の始まりと終わり（普段の起こす決まりを見た後）を今の定義と共に知らせる。返した部品は
/// 走らせ役が「今すぐ」で起こす。起こすか見届けるかは知らせのたびに今の定義の予定の種類で決める——一巡の間に予定だけを
/// 書き換えても一巡は続くので、流し始めの定義で決めると今の予定とずれる。道の形（入力・行き先）が変わる書き換えは部品を
/// 番人から外すので、一巡はそこで打ち切られる。
struct AutomationFlow {
  enum Target: Equatable {
    case part(String)
    /// 終わりの部品すべて（`AutomationGraph.ends`）。
    case ends
    /// タスク候補を行き先にする部品すべて（`AutomationGraph.judges`）。
    case judges
  }

  private enum Step: Equatable {
    /// 道の上の上流で、まだ終わっていないもの。
    case waiting(Set<String>)
    /// 道の上の上流がすべて終わった。「届いたら」なら走っていなければ終わり、そうでなければ次に始まる契機を一巡の分として
    /// 受け取る（走っていなければ起こす）。
    case ready
    /// 一巡の分の契機が走っている。`marked` が偽なのは流し始めに走っていた入力の無い部品の回で、次の終わりがその回のもの。
    case taken(marked: Bool)
    case done
  }

  private let targets: [String]
  private var steps: [String: Step] = [:]

  /// 流し始める。`wake` は今すぐ起こす部品（走っていない入力の無い部品）。入力の無い部品が走っていれば、その回を一巡の分にする
  /// （入力が無いので、いつ始まった回でも出すものは同じ）。
  static func start(
    to targets: [String], in graph: AutomationGraph, running: (String) -> Bool
  ) -> (flow: AutomationFlow, wake: [String]) {
    var flow = AutomationFlow(targets: targets)
    var wake: [String] = []
    let path = Set(targets + targets.flatMap { graph.ancestors(of: $0).map(\.key) })
    for node in graph.nodes where path.contains(node.key) {
      if !node.part.inputs.isEmpty {
        flow.steps[node.key] = .waiting(Set(node.part.inputs))
      } else if running(node.key) {
        flow.steps[node.key] = .taken(marked: false)
      } else {
        flow.steps[node.key] = .ready
        wake.append(node.key)
      }
    }
    return (flow, wake)
  }

  private init(targets: [String]) {
    self.targets = targets
  }

  var path: Set<String> { Set(steps.keys) }

  var finished: Bool { targets.allSatisfy { steps[$0] == .done } }

  /// 部品の契機が始まった。一巡の分として受け取ったら真（走らせ役はその契機に印を立てる）。誰が始めた回かは問わない。
  mutating func started(_ part: String, in graph: AutomationGraph) -> Bool {
    guard steps[part] == .ready, !Self.arrives(part, in: graph) else { return false }
    steps[part] = .taken(marked: true)
    return true
  }

  /// 部品の契機が終わった。返すのは今すぐ起こす部品。入力のある部品は印の立った契機の終わりだけを数える——番人は回の終わりの
  /// 中で次の予定の回を同期に始めうるので、古い回の終わりが受け取った回の始まりより後に届く。印の無い回の終わりは、起こす
  /// 部品を邪魔していた回が終わったとして、走っていなければ起こし直す。
  mutating func ended(
    _ part: String, marked: Bool, in graph: AutomationGraph, running: (String) -> Bool
  ) -> [String] {
    switch steps[part] {
    case .taken(let wanted) where marked || !wanted:
      return finish(part, graph, running)
    case .ready:
      return settle(part, graph, running)
    default:
      return []
    }
  }

  /// 部品を終わりにし、道の上の上流がすべて終わった下流を次へ進める。
  private mutating func finish(
    _ part: String, _ graph: AutomationGraph, _ running: (String) -> Bool
  ) -> [String] {
    steps[part] = .done
    var wake: [String] = []
    for node in graph.downstream(of: part) {
      guard case .waiting(var upstream) = steps[node.key] else { continue }
      upstream.remove(part)
      guard upstream.isEmpty else {
        steps[node.key] = .waiting(upstream)
        continue
      }
      steps[node.key] = .ready
      wake += settle(node.key, graph, running)
    }
    return wake
  }

  /// 上流がすべて終わった部品を、走っていなければ進める——「届いたら」なら終わりにし、そうでなければ起こす。
  private mutating func settle(
    _ part: String, _ graph: AutomationGraph, _ running: (String) -> Bool
  ) -> [String] {
    guard !running(part) else { return [] }
    return Self.arrives(part, in: graph) ? finish(part, graph, running) : [part]
  }

  private static func arrives(_ part: String, in graph: AutomationGraph) -> Bool {
    graph.node(part)?.part.trigger == .arrival
  }
}
