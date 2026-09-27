import Foundation
import TreeSitter

/// 言語の口のうち、取り出し 1 回ぶんの状態を持たない言語（Swift・Go・HTML・CSS）。
extension OutlineItems {
  // MARK: - Swift

  /// Swift の関数・init・プロトコルの関数はセレクタの形 `emit(_:coalesce:)`（sourcekit-lsp と同じ）。ラベルは引数の外部名、
  /// 無ければ内部名。1 つの宣言に並べた変数（`var a = 1, b = 2`）は名前ごとに出し、範囲は名前から値まで。`// MARK:` は
  /// 印を外した字を名前にする。
  func swift(_ match: OutlineMatch) -> [OutlineExtraction.Item] {
    switch Self.nodeType(match.item) {
    case "function_declaration", "init_declaration", "protocol_function_declaration":
      return [Self.swiftSelector(match)]
    case "property_declaration": return Self.swiftBindings(match)
    case "comment", "multiline_comment": return [Self.swiftMark(match)]
    default: return [Self.plain(match)]
    }
  }

  private static func swiftSelector(_ match: OutlineMatch) -> OutlineExtraction.Item {
    var item = plain(match)
    var labels = ""
    for child in namedChildren(of: match.item) where nodeType(child) == "parameter" {
      let external = ts_node_child_by_field_name(child, "external_name", 13)
      let label =
        ts_node_is_null(external)
        ? firstChild(of: child, field: "name", type: "simple_identifier") : external
      labels += (label.map(match.text) ?? "_") + ":"
    }
    item.name += "(\(labels))"
    return item
  }

  /// 名前が 1 つなら宣言全体、複数なら名前ごと（名前から、次の名前の手前の最後の子まで）を範囲にする。
  private static func swiftBindings(_ match: OutlineMatch) -> [OutlineExtraction.Item] {
    let children = (0..<ts_node_child_count(match.item)).map { index in
      (
        field: ts_node_field_name_for_child(match.item, index).map { String(cString: $0) },
        node: ts_node_child(match.item, index)
      )
    }
    let names = children.indices.filter { children[$0].field == "name" }
    guard names.count > 1 else { return [plain(match)] }
    return names.enumerated().map { ordinal, index in
      let next = ordinal + 1 < names.count ? names[ordinal + 1] : children.count
      let last = children[index..<next].last { ts_node_is_named($0.node) }!.node
      let name = children[index].node
      let bound = ts_node_child_by_field_name(name, "bound_identifier", 16)
      let nameNode = ts_node_is_null(bound) ? name : bound
      let start = range(of: name).location
      return OutlineExtraction.Item(
        range: NSRange(location: start, length: NSMaxRange(range(of: last)) - start),
        nameRange: range(of: nameNode), name: collapsed(match.text(nameNode)), kind: match.kind,
        node: 0)
    }
  }

  /// sourcekit-lsp と同じく、両端の `/`・`*`・空白を落とし、`MARK:` の後ろを名前にする（`// MARK: - Foo` は `- Foo`）。
  private static func swiftMark(_ match: OutlineMatch) -> OutlineExtraction.Item {
    var item = plain(match)
    let trimmed = match.text(match.item).trimmingCharacters(
      in: CharacterSet(charactersIn: "/*").union(.whitespacesAndNewlines))
    item.name = String(trimmed.dropFirst("MARK:".count)).trimmingCharacters(in: .whitespaces)
    return item
  }

  // MARK: - Go

  /// gopls と同じく、関数の中（本体・引数の無名の型）は出さない。メソッドの名前は `(*Server).Start`。レシーバの型と名前は
  /// 規則が `@name` に取る。
  func go(_ match: OutlineMatch) -> [OutlineExtraction.Item] {
    let functions: Set = ["function_declaration", "method_declaration", "func_literal"]
    var ancestor = ts_node_parent(match.item)
    while !ts_node_is_null(ancestor) {
      if functions.contains(Self.nodeType(ancestor)) { return [] }
      ancestor = ts_node_parent(ancestor)
    }
    var item = Self.plain(match)
    guard Self.nodeType(match.item) == "method_declaration", match.names.count == 2 else {
      return [item]
    }
    let names = match.names.sorted { ts_node_start_byte($0) < ts_node_start_byte($1) }
    item.name = "(\(Self.collapsed(match.text(names[0])))).\(match.text(names[1]))"
    return [item]
  }

  // MARK: - HTML

  /// HTML の要素は `tag#id.class1.class2`（VS Code の HTML と同じ形）。空の id・class は印を付けない。属性は開始タグか
  /// 自己終了タグから読む。
  func htmlElement(_ match: OutlineMatch) -> OutlineExtraction.Item {
    var item = Self.plain(match)
    let tag = Self.namedChildren(of: match.item).first {
      ["start_tag", "self_closing_tag"].contains(Self.nodeType($0))
    }
    guard let tag else { return item }
    var id = ""
    var classes = ""
    for attribute in Self.namedChildren(of: tag) where Self.nodeType(attribute) == "attribute" {
      let children = Self.namedChildren(of: attribute)
      guard let name = children.first(where: { Self.nodeType($0) == "attribute_name" }),
        let value = children.first(where: { Self.nodeType($0) != "attribute_name" }).map({ node in
          Self.nodeType(node) == "quoted_attribute_value"
            ? Self.namedChildren(of: node).first.map(match.text) ?? "" : match.text(node)
        })
      else { continue }
      switch match.text(name).lowercased() {
      case "id": id = value.isEmpty ? "" : "#" + value
      case "class": classes = value.split(whereSeparator: \.isWhitespace).map { "." + $0 }.joined()
      default: continue
      }
    }
    item.name += id + classes
    return item
  }

  // MARK: - CSS

  /// カンマで並んだセレクタ（`selectors` の名前つきの子）は 1 つずつ別のシンボル（範囲は同じ規則）にする。`@keyframes` は
  /// 接頭辞の付いたもの（`@-webkit-keyframes`）も `@keyframes 名前`（VS Code の CSS と同じ）。
  func css(_ match: OutlineMatch) -> [OutlineExtraction.Item] {
    if Self.nodeType(match.item) == "keyframes_statement" {
      var item = Self.plain(match)
      item.name = "@keyframes " + item.name
      return [item]
    }
    guard match.names.count == 1, let selectors = match.names.first,
      Self.nodeType(selectors) == "selectors"
    else { return [Self.plain(match)] }
    let range = Self.range(of: match.item)
    let parts = Self.namedChildren(of: selectors).filter { Self.nodeType($0) != "comment" }
    return parts.map { selector in
      OutlineExtraction.Item(
        range: range, nameRange: Self.range(of: selector),
        name: Self.collapsed(match.text(selector)), kind: match.kind, node: 0)
    }
  }
}
