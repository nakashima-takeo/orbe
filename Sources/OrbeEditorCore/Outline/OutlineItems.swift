import Foundation
import TreeSitter

/// 取り出し 1 回ぶんの言語の口。マッチ 1 つ → 0〜n 個のシンボル（`items`）と、全部が揃った後の手直し（`finish`）。既定は
/// 1 マッチ → 1 シンボル（名前は `@context` と `@name` の字）で、手直しは無い。規則だけでは VS Code の言語サーバの名付け・
/// 入れ子に届かない言語の手直しはこの型に閉じ、節の種類の知識は規則とこの型にしか無い。
struct OutlineItems {
  private let grammar: Grammar
  /// JSON: 配列の節 → 値の子の頭（昇順）。配列ごとに 1 度だけ数える。
  private var arrayElements: [UInt: [UInt32]] = [:]
  /// Markdown: 見出しの節 → 段。
  private var headingLevels: [UInt: Int] = [:]
  /// Python: 型の付いた宣言（関数・クラスと、注釈の付いた代入・引数）の節。
  private var typedDeclarations: Set<UInt> = []
  /// Dockerfile: ファイルの頭のパーサーディレクティブの節（初めて問われたときに数える）。
  private var directives: Set<UInt>?

  init(grammar: Grammar) {
    self.grammar = grammar
  }

  mutating func items(for match: OutlineMatch) -> [OutlineExtraction.Item] {
    switch grammar {
    case .swift: return swift(match)
    case .go: return go(match)
    case .html: return [htmlElement(match)]
    case .css: return css(match)
    case .json: return [json(match)]
    case .markdown: return [markdownHeading(match)]
    case .python: return [python(match)]
    case .dockerfile: return dockerfile(match)
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

  // MARK: - JSON

  /// オブジェクトのキーはエスケープをほどいた値（改行は `↵`。空白だけか空なら引用符で囲む。VS Code の JSON と同じ）。
  /// 配列の要素は、配列の中での番号（0 始まり。前にある値の数）を名前にする。
  private mutating func json(_ match: OutlineMatch) -> OutlineExtraction.Item {
    var item = Self.plain(match)
    if let key = match.names.first, Self.nodeType(match.item) == "pair" {
      let value = Self.unescapedJSON(match.text(key)).replacingOccurrences(of: "\n", with: "↵")
      item.name =
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "\"\(value)\"" : value
      return item
    }
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

  /// JSON の文字列の字（引用符を含む）のエスケープをほどいた値。読めないエスケープは字のまま残す。
  private static func unescapedJSON(_ literal: String) -> String {
    var units = Array(literal.utf16)
    if units.first == 0x22 { units.removeFirst() }
    if units.last == 0x22 { units.removeLast() }
    var result: [UInt16] = []
    result.reserveCapacity(units.count)
    var index = 0
    while index < units.count {
      let unit = units[index]
      index += 1
      guard unit == 0x5C, index < units.count else {
        result.append(unit)
        continue
      }
      let escaped = units[index]
      index += 1
      switch escaped {
      case 0x22, 0x5C, 0x2F: result.append(escaped)
      case 0x62: result.append(0x08)
      case 0x66: result.append(0x0C)
      case 0x6E: result.append(0x0A)
      case 0x72: result.append(0x0D)
      case 0x74: result.append(0x09)
      case 0x75
      where index + 4 <= units.count
        && UInt16(String(utf16CodeUnits: Array(units[index..<index + 4]), count: 4), radix: 16)
          != nil:
        result.append(
          UInt16(String(utf16CodeUnits: Array(units[index..<index + 4]), count: 4), radix: 16)!)
        index += 4
      default: result.append(contentsOf: [unit, escaped])
      }
    }
    return String(utf16CodeUnits: result, count: result.count)
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

  // MARK: - Dockerfile

  /// 命令と、ファイルの頭のパーサーディレクティブ（`# syntax=…`。名前はディレクティブの名。VS Code の Dockerfile と同じ）。
  /// ディレクティブは 1 行目から空行を挟まずに続く `# 名前=値` のコメントだけで、それより後ろはただのコメント。
  private mutating func dockerfile(_ match: OutlineMatch) -> [OutlineExtraction.Item] {
    guard Self.nodeType(match.item) == "comment" else { return [Self.plain(match)] }
    if directives == nil {
      directives = Self.leadingDirectives(in: ts_node_parent(match.item), text: match.text)
    }
    guard directives!.contains(Self.id(match.item)),
      let name = Self.directiveName(match.text(match.item))
    else { return [] }
    var item = Self.plain(match)
    item.name = name
    return [item]
  }

  /// ファイルの頭から続くディレクティブのコメントの節。
  private static func leadingDirectives(in file: TSNode, text: (TSNode) -> String) -> Set<UInt> {
    var found: Set<UInt> = []
    var cursor = ts_tree_cursor_new(file)
    defer { ts_tree_cursor_delete(&cursor) }
    guard ts_tree_cursor_goto_first_child(&cursor) else { return found }
    repeat {
      let child = ts_tree_cursor_current_node(&cursor)
      guard nodeType(child) == "comment", Int(ts_node_start_point(child).row) == found.count,
        directiveName(text(child)) != nil
      else { break }
      found.insert(id(child))
    } while ts_tree_cursor_goto_next_sibling(&cursor)
    return found
  }

  /// `# 名前=値` の名前（名前は英字で始まる英数字）。形が違えば nil。
  private static func directiveName(_ comment: String) -> String? {
    let body = comment.dropFirst().drop { $0 == " " || $0 == "\t" }
    let name = body.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }
    guard let first = name.first, first.isLetter,
      body.dropFirst(name.count).drop(while: { $0 == " " || $0 == "\t" }).first == "="
    else { return nil }
    return String(name)
  }
}

/// 節を読む道具（言語の口が共有する）。
extension OutlineItems {
  static func id(_ node: TSNode) -> UInt {
    UInt(bitPattern: node.id)
  }

  static func range(of node: TSNode) -> NSRange {
    let start = Int(ts_node_start_byte(node)) / 2
    return NSRange(location: start, length: Int(ts_node_end_byte(node)) / 2 - start)
  }

  /// 節の列が占める範囲（頭の最小から終わりの最大）。空なら nil。
  static func span(_ nodes: [TSNode]) -> NSRange? {
    guard !nodes.isEmpty else { return nil }
    let start = nodes.map { range(of: $0).location }.min()!
    return NSRange(location: start, length: nodes.map { NSMaxRange(range(of: $0)) }.max()! - start)
  }

  static func nodeType(_ node: TSNode) -> String {
    String(cString: ts_node_type(node))
  }

  static func namedChildren(of node: TSNode) -> [TSNode] {
    (0..<ts_node_named_child_count(node)).map { ts_node_named_child(node, $0) }
  }

  static func firstChild(of node: TSNode, field: String, type: String) -> TSNode? {
    (0..<ts_node_child_count(node)).lazy.compactMap { index -> TSNode? in
      guard let name = ts_node_field_name_for_child(node, index), String(cString: name) == field
      else { return nil }
      let child = ts_node_child(node, index)
      return nodeType(child) == type ? child : nil
    }.first
  }

  /// 節の字を位置順に連ねる（節の間にすき間があれば空白 1 つ）。
  static func joined(_ nodes: [TSNode], _ text: (TSNode) -> String) -> String {
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
