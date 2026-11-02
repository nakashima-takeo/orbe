import Foundation

// 定義の JSON の workspace の席（最上位と `nodes[i]`）の、外の形と保存の形の写し。外の形は起動ごとの ID（`list_workspaces` の
// `id`）、保存の形は `Workspace.persistentId` の文字列。定義の型は保存の形だけを読み書きし、写しは制御の境界でここを通す。

extension AutomationWorkspaces {
  /// 外の形の定義を保存の形へ。整数でない値・`null`（消えた workspace の書き戻し）・知らない ID を、定義の中の場所で断る。
  /// 席の外の形の誤りは写さずに残す（定義の読みが場所付きで断る）。
  func inward(_ definition: [String: Any]) throws(AutomationError) -> [String: Any] {
    var definition = definition
    try inward(&definition, at: "workspace")
    if var nodes = definition["nodes"] as? [Any] {
      for index in nodes.indices {
        guard var node = nodes[index] as? [String: Any] else { continue }
        try inward(&node, at: "nodes[\(index)].workspace")
        nodes[index] = node
      }
      definition["nodes"] = nodes
    }
    return definition
  }

  /// 保存の形の定義を外の形へ。今の workspace に解けない席は `null`——ノードの席で「書かない」は自動化の workspace を継ぐ意味
  /// なので、消えた席を落とすと、書き戻しで黙って自動化の workspace に付け替わる。
  func outward(_ definition: [String: Any]) -> [String: Any] {
    var definition = definition
    outward(&definition)
    if var nodes = definition["nodes"] as? [Any] {
      for index in nodes.indices {
        guard var node = nodes[index] as? [String: Any] else { continue }
        outward(&node)
        nodes[index] = node
      }
      definition["nodes"] = nodes
    }
    return definition
  }

  private func inward(_ object: inout [String: Any], at path: String) throws(AutomationError) {
    guard let raw = object["workspace"] else { return }
    if raw is NSNull {
      throw .invalid(
        "\(path): the workspace was removed; pass a workspace id from list_workspaces or leave "
          + "workspace out")
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
