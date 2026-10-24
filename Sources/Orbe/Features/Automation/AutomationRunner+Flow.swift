import Foundation

/// 流す——部品を指して、そこに至る道の上の部品を 1 回ずつ回す（`AutomationFlow`）。
extension AutomationRunner {
  /// 流している途中か（一巡があるか）。
  func isFlowing(_ id: Int) -> Bool {
    flows[id] != nil
  }

  /// 流している途中の一巡。
  func currentFlow(_ id: Int) -> AutomationFlow? {
    flows[id]
  }

  /// 指した部品まで流す（止めた自動化も受ける）。流している途中なら断る。指す部品が無ければ一巡を置かない（置くと終わりの
  /// 知らせが来ず、以後ずっと断る）。
  func flow(_ id: Int, to target: AutomationFlow.Target) throws(AutomationError) {
    try checkAvailable()
    let automation = store.automations[try store.index(id)]
    let targets: [AutomationNodeID]
    switch target {
    case .node(let nodeId):
      guard automation.graph.node(nodeId) != nil else { throw .nodeNotFound(id, "\(nodeId)") }
      targets = [nodeId]
    case .ends:
      targets = automation.graph.ends.map(\.id)
    case .judges:
      targets = automation.graph.judges.map(\.id)
    }
    guard flows[id] == nil else { throw .flowing(id) }
    guard !targets.isEmpty else { return }
    let path = Set(targets + targets.flatMap { automation.graph.ancestors(of: $0).map(\.id) })
    try flow(id, through: path, to: targets)
  }

  /// 道（`path`）を渡して、その上を `targets`（空でなく、どれも道の上）まで流す。流している途中なら断る。
  func flow(_ id: Int, through path: Set<AutomationNodeID>, to targets: [AutomationNodeID])
    throws(AutomationError)
  {
    try checkAvailable()
    guard let graph = store.automation(id)?.graph else { throw .automationNotFound(id) }
    guard flows[id] == nil else { throw .flowing(id) }
    let (flow, wake) = AutomationFlow.start(through: path, to: targets, in: graph) {
      isRunning(id, $0)
    }
    // 「今すぐ」の中で契機が同期に始まり終わりうるので、起こす前に一巡を置く。
    flows[id] = flow
    for nodeId in wake { scheduler.runNow(id: Self.key(id, nodeId)) }
  }
}
