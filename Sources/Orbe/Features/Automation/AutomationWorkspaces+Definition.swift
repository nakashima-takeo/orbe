import Foundation

// 定義の JSON の workspace の席（最上位とコマンドのノード）の、外の形と保存の形の写し。外の形は起動ごとの ID（`list_workspaces`
// の `id`）、保存の形は `Workspace.persistentId` の文字列。定義の型は保存の形だけを読み書きし、写しは制御の境界でここを通す。
// agent のノードの席は写さない（定義の読みが値によらず断る）。

extension AutomationWorkspaces {
  /// 外の形の定義を保存の形へ。整数でない値・`null`・知らない ID を、定義の中の場所で断る。`null` の断りは、席を外したときに
  /// どこで走るかを言う——ノードの席で「書かない」は自動化の workspace を継ぐ意味で、消えた workspace の席を外すと別の
  /// workspace で走りうるため。席の外の形の誤りは写さずに残す（定義の読みが場所付きで断る）。
  func inward(_ definition: [String: Any]) throws(AutomationError) -> [String: Any] {
    var definition = definition
    try inward(
      &definition, at: "workspace",
      leftOut: "leave workspace out and give its command nodes absolute directories")
    let inherited = definition["workspace"] != nil
    try commandNodes(&definition) { node, index throws(AutomationError) in
      try inward(
        &node, at: "nodes[\(index)].workspace",
        leftOut: inherited
          ? "leave workspace out to run in the automation's workspace"
          : "leave workspace out and give the node an absolute directory")
    }
    return definition
  }

  /// 保存の形の定義を外の形へ。今の workspace に解けない席は `null`——ノードの席で「書かない」は自動化の workspace を継ぐ意味
  /// なので、消えた席を落とすと、書き戻しで黙って自動化の workspace に付け替わる。
  func outward(_ definition: [String: Any]) -> [String: Any] {
    var definition = definition
    outward(&definition)
    commandNodes(&definition) { node, _ in outward(&node) }
    return definition
  }

  private func commandNodes<E: Error>(
    _ definition: inout [String: Any], _ body: (inout [String: Any], Int) throws(E) -> Void
  ) throws(E) {
    guard var nodes = definition["nodes"] as? [Any] else { return }
    for index in nodes.indices {
      guard var node = nodes[index] as? [String: Any], node["command"] != nil else { continue }
      try body(&node, index)
      nodes[index] = node
    }
    definition["nodes"] = nodes
  }

  private func inward(_ object: inout [String: Any], at path: String, leftOut: String)
    throws(AutomationError)
  {
    guard let raw = object["workspace"] else { return }
    if raw is NSNull {
      throw .invalid(
        "\(path): null names no workspace (a removed workspace is listed as null); pass a "
          + "workspace id from list_workspaces, or \(leftOut)")
    }
    guard !Self.isBool(raw), let id = raw as? Int else {
      throw .invalid("invalid \(path): pass a workspace id from list_workspaces")
    }
    guard let workspace = all.first(where: { $0.id == id }) else {
      throw .invalid("\(path): unknown workspace \(id)")
    }
    object["workspace"] = workspace.persistentId.uuidString
  }

  private func outward(_ object: inout [String: Any]) {
    guard let raw = object["workspace"] else { return }
    let id = (raw as? String).flatMap(UUID.init(uuidString:)).flatMap(workspace)?.id
    object["workspace"] = id.map { $0 as Any } ?? NSNull()
  }

  /// JSONSerialization は true / false も NSNumber に載せ `as? Int` を通す。
  private static func isBool(_ raw: Any) -> Bool {
    (raw as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
  }
}
