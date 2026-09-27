import Foundation
import TreeSitter

/// 取り出し 1 回ぶんの言語の口。マッチ 1 つ → 0〜n 個のシンボル。既定は 1 マッチ → 1 シンボル（名前は `@context` と
/// `@name` の字）。規則だけでは VS Code の言語サーバの名付けに届かない言語（Swift・Go・HTML・CSS・JSON）の手直しはここに
/// 閉じ、節の種類の知識は規則とここにしか無い。
struct OutlineItems {
  private let grammar: Grammar
  /// JSON: 配列の節 → 値の子の頭（昇順）。配列ごとに 1 度だけ数える。
  private var arrayElements: [UInt: [UInt32]] = [:]
  /// Markdown: 見出しの節 → 段。
  private var headingLevels: [UInt: Int] = [:]
  /// Python: 型の付いた宣言（関数・クラスと、注釈の付いた代入・引数）の節。
  private var typedDeclarations: Set<UInt> = []

  init(grammar: Grammar) {
    self.grammar = grammar
  }

  mutating func items(for match: OutlineMatch) -> [OutlineExtraction.Item] {
    switch grammar {
    case .swift: return swift(match)
    case .go: return go(match)
    case .html: return [Self.htmlElement(match)]
    case .css: return Self.cssSelectors(match)
    case .json: return [jsonArrayElement(match)]
    case .markdown: return [markdownHeading(match)]
    case .python: return [python(match)]
    default: return [Self.plain(match)]
    }
  }

  /// 全部のシンボルが揃った後の手直し。`length` は本文の長さ（UTF-16）。
  func finish(_ items: [OutlineExtraction.Item], length: Int) -> [OutlineExtraction.Item] {
    switch grammar {
    case .markdown: return nestHeadingsByLevel(items, length: length)
    case .python: return mergeSameNames(items)
    default: return items
    }
  }

  /// `@context` と `@name` を連ねた名前（節の間にすき間があれば空白 1 つ）。名前の範囲は `@target` の節、無ければ名前の
  /// 節が占める範囲。名前の節も無ければ名前は空で、範囲は item の頭。
  static func plain(_ match: OutlineMatch) -> OutlineExtraction.Item {
    let range = range(of: match.item)
    let name = [joined(match.contexts, match.text), joined(match.names, match.text)]
      .filter { !$0.isEmpty }.joined(separator: " ")
    return OutlineExtraction.Item(
      range: range,
      nameRange: span(match.targets.isEmpty ? match.contexts + match.names : match.targets)
        ?? NSRange(location: range.location, length: 0),
      name: name, kind: match.kind, node: 0)
  }

  // MARK: - Swift

  /// Swift の関数・init・プロトコルの関数はセレクタの形 `emit(_:coalesce:)`（sourcekit-lsp と同じ）。ラベルは引数の外部名、
  /// 無ければ内部名。1 つの宣言に並べた変数（`var a = 1, b = 2`）は名前ごとに出し、範囲は名前から値まで。`// MARK:` は
  /// 印を外した字を名前にする。
  private func swift(_ match: OutlineMatch) -> [OutlineExtraction.Item] {
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
      (field: ts_node_field_name_for_child(match.item, index).map { String(cString: $0) },
        node: ts_node_child(match.item, index))
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
  private func go(_ match: OutlineMatch) -> [OutlineExtraction.Item] {
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

  // MARK: - Markdown

  /// 見出しの名前は印と見出しの字（`## Usage`。VS Code と同じく setext も段の数の `#`、閉じの `#` は含めない）。段は
  /// `finish` が入れ子に使う。
  private mutating func markdownHeading(_ match: OutlineMatch) -> OutlineExtraction.Item {
    var item = Self.plain(match)
    let content = Self.joined(match.names, match.text)
    let level: Int
    if Self.nodeType(match.item) == "setext_heading" {
      let underline = Self.namedChildren(of: match.item).last.map(Self.nodeType)
      level = underline == "setext_h1_underline" ? 1 : 2
    } else {
      level = match.contexts.first.map { match.text($0).count } ?? 1
    }
    let text = Self.withoutClosingSequence(content)
    item.name = String(repeating: "#", count: level) + (text.isEmpty ? "" : " " + text)
    headingLevels[Self.id(match.item)] = level
    return item
  }

  /// ATX 見出しの閉じの `#` の並び（前に空白があるもの）を落とす。
  private static func withoutClosingSequence(_ content: String) -> String {
    let body = content.trimmingCharacters(in: .whitespaces)
    let hashes = body.reversed().prefix { $0 == "#" }.count
    guard hashes > 0 else { return body }
    let rest = body.dropLast(hashes)
    guard rest.isEmpty || rest.last!.isWhitespace else { return body }
    return rest.trimmingCharacters(in: .whitespaces)
  }

  /// 見出しを段で入れ子にする（VS Code と同じ）——範囲を、次の同じか浅い段の見出しの手前（無ければ本文の終わり）まで
  /// 伸ばす。範囲の包含で入れ子にする仕組みにそのまま乗る。
  private func nestHeadingsByLevel(_ items: [OutlineExtraction.Item], length: Int)
    -> [OutlineExtraction.Item]
  {
    let order = items.indices.sorted { items[$0].range.location < items[$1].range.location }
    var result = items
    var open: [Int] = []
    for index in order {
      let level = headingLevels[items[index].node] ?? 1
      while let last = open.last, headingLevels[items[last].node] ?? 1 >= level {
        close(last, at: items[index].range.location)
        open.removeLast()
      }
      open.append(index)
    }
    for index in open { close(index, at: length) }
    return result

    func close(_ index: Int, at end: Int) {
      let start = result[index].range.location
      result[index].range = NSRange(location: start, length: max(end, start) - start)
    }
  }

  // MARK: - Python

  private mutating func python(_ match: OutlineMatch) -> OutlineExtraction.Item {
    let item = Self.plain(match)
    if Self.isTypedPythonDeclaration(match.item) { typedDeclarations.insert(Self.id(match.item)) }
    return item
  }

  /// pyright が型の付いた宣言と見るもの。item が名前の節（代入・引数）なら、その親に型の注釈があるか。
  private static func isTypedPythonDeclaration(_ node: TSNode) -> Bool {
    switch nodeType(node) {
    case "function_definition", "class_definition", "decorated_definition": return true
    case "identifier":
      let parent = ts_node_parent(node)
      guard !ts_node_is_null(parent) else { return false }
      switch nodeType(parent) {
      case "assignment": return !ts_node_is_null(ts_node_child_by_field_name(parent, "type", 4))
      case "typed_parameter", "typed_default_parameter": return true
      default: return false
      }
    default: return false
    }
  }

  /// 同じ入れ子の中の同じ名前は 1 つにまとめる（pyright の記号表と同じ）。残すのは型の付いた最後の宣言、無ければ最初の
  /// 宣言で、残さなかったものは部分木ごと落とす。
  private func mergeSameNames(_ items: [OutlineExtraction.Item]) -> [OutlineExtraction.Item] {
    struct Scope: Hashable {
      let parent: Int?
      let name: String
    }
    let arrangement = OutlineExtraction.arrange(items)
    var kept: [Scope: Int] = [:]
    for position in arrangement.order.indices {
      let item = items[arrangement.order[position]]
      let scope = Scope(parent: arrangement.parents[position], name: item.name)
      if kept[scope] == nil || typedDeclarations.contains(item.node) { kept[scope] = position }
    }
    let keep = Set(kept.values)
    var result: [OutlineExtraction.Item] = []
    var position = 0
    while position < arrangement.order.count {
      guard keep.contains(position) else {
        position = arrangement.ends[position]
        continue
      }
      result.append(items[arrangement.order[position]])
      position += 1
    }
    return result
  }

  // MARK: - 節の道具

  private static func id(_ node: TSNode) -> UInt {
    UInt(bitPattern: node.id)
  }

  private static func range(of node: TSNode) -> NSRange {
    let start = Int(ts_node_start_byte(node)) / 2
    return NSRange(location: start, length: Int(ts_node_end_byte(node)) / 2 - start)
  }

  /// 節の列が占める範囲（頭の最小から終わりの最大）。空なら nil。
  private static func span(_ nodes: [TSNode]) -> NSRange? {
    guard !nodes.isEmpty else { return nil }
    let start = nodes.map { range(of: $0).location }.min()!
    return NSRange(location: start, length: nodes.map { NSMaxRange(range(of: $0)) }.max()! - start)
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
