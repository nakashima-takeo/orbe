import Foundation

extension AutomationWorkspaces {
  /// 定義の workspace の席（最上位とコマンドのノード）が、どれも今の workspace を指すかを確かめる。無い席は、席を外したときに
  /// どこで走るかを添えて断る——ノードの席で「書かない」は自動化の workspace を継ぐ意味で、消えた workspace の席を外すと別の
  /// workspace で走りうるため。書くときだけ確かめる（保存した定義は、後で workspace が消えても定義として正しい）。
  func checkSeats(of definition: AutomationDefinition) throws(AutomationError) {
    try check(
      definition.workspace, at: "workspace",
      leftOut: "leave workspace out and give its command nodes absolute directories")
    for (index, node) in definition.nodes.enumerated() {
      guard case .command(let command) = node.action.method else { continue }
      try check(
        command.workspace, at: "nodes[\(index)].workspace",
        leftOut: definition.workspace != nil
          ? "leave workspace out to run in the automation's workspace"
          : "leave workspace out and give the node an absolute directory")
    }
  }

  private func check(_ id: UUID?, at path: String, leftOut: String) throws(AutomationError) {
    guard let id, workspace(id) == nil else { return }
    throw .invalid(
      "\(path): unknown workspace \(id.uuidString) (it may have been removed); pass a workspace id "
        + "from list_workspaces, or \(leftOut)")
  }
}
