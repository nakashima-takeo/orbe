import Foundation
import TreeSitter

/// 取り出し 1 回ぶんの言語の口。マッチ 1 つ → 0〜n 個のシンボル。既定は 1 マッチ → 1 シンボル（名前は `@context` と
/// `@name` の字）。規則だけでは VS Code の言語サーバの名付けに届かない言語（Swift・Go・HTML・CSS・JSON）の手直しはここに
/// 閉じ、節の種類の知識は規則とここにしか無い。
struct OutlineItems {
  private let grammar: Grammar
  /// JSON: 配列の節 → 値の子の頭（昇順）。配列ごとに 1 度だけ数える。
  private var arrayElements: [UInt: [UInt32]] = [:]

  init(grammar: Grammar) {
    self.grammar = grammar
  }

  mutating func items(for match: OutlineMatch) -> [OutlineExtraction.Item] {
    switch grammar {
    case .swift: return [Self.swiftSelector(match)]
    case .go: return [Self.goMethod(match)]
    case .html: return [Self.htmlElement(match)]
    case .css: return Self.cssSelectors(match)
    case .json: return [jsonArrayElement(match)]
    default: return [Self.plain(match)]
    }
  }

  /// `@context` と `@name` を連ねた名前（節の間にすき間があれば空白 1 つ）と、それが占める範囲。名前の節が無ければ
  /// 名前は空で、範囲は item の頭。
  static func plain(_ match: OutlineMatch) -> OutlineExtraction.Item {
    let parts = match.contexts + match.names
    let range = range(of: match.item)
    let nameRange =
      parts.isEmpty
      ? NSRange(location: range.location, length: 0)
      : NSRange(
        location: parts.map { self.range(of: $0).location }.min()!,
        length: parts.map { NSMaxRange(self.range(of: $0)) }.max()!
          - parts.map { self.range(of: $0).location }.min()!)
    let name = [joined(match.contexts, match.text), joined(match.names, match.text)]
      .filter { !$0.isEmpty }.joined(separator: " ")
    return OutlineExtraction.Item(
      range: range, nameRange: nameRange, name: name, kind: match.kind, node: 0)
  }

  /// Swift の関数・init・プロトコルの関数・subscript はセレクタの形 `emit(_:coalesce:)`（sourcekit-lsp と同じ）。ラベルは
  /// 引数の外部名、無ければ内部名。
  static func swiftSelector(_ match: OutlineMatch) -> OutlineExtraction.Item {
    var item = plain(match)
    let callable: Set = [
      "function_declaration", "init_declaration", "protocol_function_declaration",
      "subscript_declaration",
    ]
    guard callable.contains(nodeType(match.item)) else { return item }
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

  /// Go のメソッドは `(*Server).Start`（gopls と同じ）。レシーバの型と名前は規則が `@name` に取る。
  static func goMethod(_ match: OutlineMatch) -> OutlineExtraction.Item {
    var item = plain(match)
    guard nodeType(match.item) == "method_declaration", match.names.count == 2 else { return item }
    let names = match.names.sorted { ts_node_start_byte($0) < ts_node_start_byte($1) }
    item.name = "(\(collapsed(match.text(names[0])))).\(match.text(names[1]))"
    return item
  }

  /// HTML の要素は `tag#id.class1.class2`（VS Code の HTML の `nodeToName` と同じ——値のある id・class は空でも印を付け、
  /// class は空白の連なりで分ける）。属性は開始タグ（か自己終了タグ）から読む。
  static func htmlElement(_ match: OutlineMatch) -> OutlineExtraction.Item {
    var item = plain(match)
    let tag =
      nodeType(match.item) == "self_closing_tag"
      ? match.item
      : namedChildren(of: match.item).first {
        ["start_tag", "self_closing_tag"].contains(nodeType($0))
      }
    guard let tag else { return item }
    var id = ""
    var classes = ""
    for attribute in namedChildren(of: tag) where nodeType(attribute) == "attribute" {
      let children = namedChildren(of: attribute)
      guard let name = children.first(where: { nodeType($0) == "attribute_name" }),
        let value = children.first(where: { nodeType($0) != "attribute_name" }).map({ node in
          nodeType(node) == "quoted_attribute_value"
            ? namedChildren(of: node).first.map(match.text) ?? "" : match.text(node)
        })
      else { continue }
      switch match.text(name).lowercased() {
      case "id": id = "#" + value
      case "class": classes = whitespaceRuns(value).map { "." + $0 }.joined()
      default: continue
      }
    }
    item.name += id + classes
    return item
  }

  /// 空白の連なりで分ける（JS の `split(/\s+/)` と同じく、端の空白は空の要素になる）。
  private static func whitespaceRuns(_ text: String) -> [Substring] {
    var parts: [Substring] = []
    var start = text.startIndex
    var index = text.startIndex
    while index < text.endIndex {
      guard text[index].isWhitespace else {
        index = text.index(after: index)
        continue
      }
      parts.append(text[start..<index])
      while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
      start = index
    }
    parts.append(text[start...])
    return parts
  }

  /// CSS のカンマで並んだセレクタ（`selectors` の名前つきの子）を、1 つずつ別のシンボル（範囲は同じ規則）にする。
  static func cssSelectors(_ match: OutlineMatch) -> [OutlineExtraction.Item] {
    guard match.names.count == 1, let selectors = match.names.first,
      nodeType(selectors) == "selectors"
    else { return [plain(match)] }
    let range = range(of: match.item)
    return namedChildren(of: selectors).filter { nodeType($0) != "comment" }.map { selector in
      OutlineExtraction.Item(
        range: range, nameRange: self.range(of: selector), name: collapsed(match.text(selector)),
        kind: match.kind, node: 0)
    }
  }

  /// JSON の配列の要素は、配列の中での番号（0 始まり。前にある値の数）を名前にする（VS Code の JSON と同じ）。
  private mutating func jsonArrayElement(_ match: OutlineMatch) -> OutlineExtraction.Item {
    var item = Self.plain(match)
    let parent = ts_node_parent(match.item)
    guard match.names.isEmpty, !ts_node_is_null(parent), Self.nodeType(parent) == "array" else {
      return item
    }
    let id = UInt(bitPattern: parent.id)
    if arrayElements[id] == nil { arrayElements[id] = Self.valueStarts(in: parent) }
    let starts = arrayElements[id]!
    let start = ts_node_start_byte(match.item)
    var low = 0
    var high = starts.count
    while low < high {
      let middle = (low + high) / 2
      if starts[middle] < start { low = middle + 1 } else { high = middle }
    }
    item.name = String(low)
    return item
  }

  /// 配列の値の子（コメントと ERROR は数えない）の頭を、子を 1 度ずつ辿って並べる。
  private static func valueStarts(in array: TSNode) -> [UInt32] {
    let values: Set = ["object", "array", "string", "number", "true", "false", "null"]
    var starts: [UInt32] = []
    var cursor = ts_tree_cursor_new(array)
    defer { ts_tree_cursor_delete(&cursor) }
    guard ts_tree_cursor_goto_first_child(&cursor) else { return starts }
    repeat {
      let child = ts_tree_cursor_current_node(&cursor)
      if ts_node_is_named(child), values.contains(nodeType(child)) {
        starts.append(ts_node_start_byte(child))
      }
    } while ts_tree_cursor_goto_next_sibling(&cursor)
    return starts
  }

  // MARK: - 節の道具

  private static func range(of node: TSNode) -> NSRange {
    let start = Int(ts_node_start_byte(node)) / 2
    return NSRange(location: start, length: Int(ts_node_end_byte(node)) / 2 - start)
  }

  private static func nodeType(_ node: TSNode) -> String {
    String(cString: ts_node_type(node))
  }

  private static func namedChildren(of node: TSNode) -> [TSNode] {
    (0..<ts_node_named_child_count(node)).map { ts_node_named_child(node, $0) }
  }

  private static func firstChild(of node: TSNode, field: String, type: String) -> TSNode? {
    (0..<ts_node_child_count(node)).lazy.compactMap { index -> TSNode? in
      guard let name = ts_node_field_name_for_child(node, index), String(cString: name) == field
      else { return nil }
      let child = ts_node_child(node, index)
      return nodeType(child) == type ? child : nil
    }.first
  }

  /// 節の字を位置順に連ねる（節の間にすき間があれば空白 1 つ）。
  private static func joined(_ nodes: [TSNode], _ text: (TSNode) -> String) -> String {
    var result = ""
    var end: UInt32?
    for node in nodes.sorted(by: { ts_node_start_byte($0) < ts_node_start_byte($1) }) {
      if let end, ts_node_start_byte(node) > end { result += " " }
      result += text(node)
      end = ts_node_end_byte(node)
    }
    return collapsed(result)
  }

  /// 改行と連続する空白を空白 1 つに畳み、両端の空白を落とす。
  static func collapsed(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
