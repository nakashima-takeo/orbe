import Foundation

/// 自動化の定義（AI から見える外の形）。書くときに動作の定義・自動化のノード・つながりへ分け、読むときに行から組み直す。
/// 形だけを読み、値と組み合わせは `checked()` が検証する。ノードの同一性は `id`（Orbe が振る）で、鍵はただの呼び名。
struct AutomationDefinition: Equatable {
  var name: String
  var notify: AutomationNotify?
  /// 自分の workspace を書かないコマンドのノードが走る workspace の `Workspace.id`。判定の付け先とは関係しない。
  var workspace: UUID?
  var nodes: [Node]

  /// 外の形のノード 1 つ。`id` は今あるノードを指す（新しく足すノードは持たない）。
  struct Node: Equatable {
    var id: AutomationNodeID?
    var key: String
    var name: String
    var trigger: AutomationNode.Trigger
    /// 入力（上流のノードの鍵と取り方）。空は入力の無いノード。
    var from: [Input]
    var action: AutomationActionDef
    /// 1 回に取る件数の上限。
    var maxItems: Int?
    /// 出来事を残す日数（出来事の流れを出すノードだけ）。
    var retentionDays: Int?

    /// 行を見るか——入力があり、ツールを持つ agent でない。
    var readsRows: Bool { !from.isEmpty && !action.hasTools }

    /// 自動化の workspace を継ぐか——自分の workspace を書かないコマンドのノード。
    var inheritsWorkspace: Bool {
      guard case .command(let command) = action.method else { return false }
      return command.workspace == nil
    }
  }

  /// `from` の要素。鍵だけの文字列は、新しい行だけを取り古さの上限を持たない。
  struct Input: Equatable {
    var nodeKey: String
    var take: AutomationTake = .new
    var maxAgeHours: Int?
  }

  /// 名前は 1 行に整え、ノードはグラフとして検証する。名前はタスクのタイトルと同じ 1 行の規則（前後の空白を除いて保存）。
  func checked() throws(AutomationError) -> (name: String, checkedNodes: [AutomationGraph.Checked])
  {
    let name: String
    do throws(TaskStoreError) {
      name = try TaskStore.validTitle(self.name)
    } catch {
      throw .invalid("name: must be a single non-empty line")
    }
    return (name, try AutomationGraph.check(nodes, workspace: workspace))
  }

  /// JSON の値を定義として読む。読めない箇所を定義の中の場所（`nodes[2].trigger` など）で言う。
  static func decode(_ object: [String: Any]) throws(AutomationError) -> AutomationDefinition {
    do {
      let data = try JSONSerialization.data(withJSONObject: object)
      return try AutomationWire.decoder.decode(AutomationDefinition.self, from: data)
    } catch {
      throw .invalid(reason(error, at: ""))
    }
  }

  /// 読みの誤りを、定義の中の場所で言う理由の文にする。`base` は読んだ値の定義の中の場所（`nodes[1]`・`nodes[1].trigger`。
  /// 定義そのものなら空）。
  static func reason(_ error: Error, at base: String) -> String {
    switch error {
    case let unknown as AutomationUnknownKey:
      return "unknown \(path(unknown.codingPath, under: base))"
    case DecodingError.keyNotFound(let key, let context):
      return "missing \(path(context.codingPath + [key], under: base))"
    case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
      return "invalid \(path(context.codingPath, under: base))"
    case DecodingError.dataCorrupted(let context):
      let at = path(context.codingPath, under: base)
      return at.isEmpty ? context.debugDescription : "invalid \(at): \(context.debugDescription)"
    default:
      return "invalid definition"
    }
  }

  /// `nodes[2].trigger` の形（定義の中の場所）。
  private static func path(_ keys: [CodingKey], under base: String) -> String {
    keys.reduce(into: base) { path, key in
      if let index = key.intValue {
        path += "[\(index)]"
      } else {
        path += path.isEmpty ? key.stringValue : "." + key.stringValue
      }
    }
  }
}
