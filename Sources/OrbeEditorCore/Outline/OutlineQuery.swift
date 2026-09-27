import Foundation
import TreeSitter

/// outline の問い合わせ（Orbe の規則 `outline/<文法>.scm`）。capture は次のとおりで、種類はパターンごとの `#set! kind`。
/// 種類の無いパターンは注釈だけを取る（シンボルは出さない）。
/// - `@item`: シンボルの節。範囲の包含で入れ子にする
/// - `@name`: 名前（複数なら位置順に連ねる）。`@context`: 名前の前に付ける字
/// - `@target`: 飛び先の節（無ければ名前の範囲）
/// - `@annotation`: item の前に続けば範囲に含める節（属性・デコレータ・doc コメント）。空行を挟んでも続く
/// - `@annotation.adjacent`: 同じく含める節（普通のコメント）。ただし空行を挟めば切れる
final class OutlineQuery: Sendable {
  let query: SyntaxQuery
  let item: UInt32
  let name: UInt32?
  let context: UInt32?
  let target: UInt32?
  let annotation: UInt32?
  let adjacentAnnotation: UInt32?
  /// パターンごとの種類。
  let kinds: [OutlineKind?]

  /// `@item` が無ければ nil。
  init?(_ query: SyntaxQuery) {
    let names = query.captureNames
    guard let item = names.firstIndex(of: "item") else { return nil }
    let index: (String) -> UInt32? = { name in names.firstIndex(of: name).map { UInt32($0) } }
    self.query = query
    self.item = UInt32(item)
    name = index("name")
    context = index("context")
    target = index("target")
    annotation = index("annotation")
    adjacentAnnotation = index("annotation.adjacent")
    kinds = query.settings.map { $0["kind"].flatMap(OutlineKind.init(rawValue:)) }
  }
}

/// 根の構文木 1 本からアウトラインを取り出す。問い合わせを木全体に 1 回かけ、マッチごとに言語の口（`OutlineItems`）で
/// シンボルを作り、注釈の分だけ範囲を前へ広げ、`@item` の節の範囲の包含で入れ子にする。cursor を持つので、使う裏の仕事の
/// 中だけで使う。
struct OutlineExtraction {
  /// 取り出したシンボル 1 つ（入れ子にする前）。位置は UTF-16。
  struct Item {
    var range: NSRange
    var nameRange: NSRange
    var name: String
    var kind: OutlineKind
    /// `@item` の節（同じ節から出たシンボルは兄弟にする）。
    var node: UInt
  }

  let query: OutlineQuery
  let grammar: Grammar
  private let cursor = QueryCursor()

  /// 打ち切りの印が立てば nil。
  func run(
    _ tree: SyntaxTree, text: TextRope, version: Int, cancellation: SyntaxCancellation
  ) -> DocumentOutline? {
    // 同じ節を複数のパターンが取ったら、規則に先に書いたパターン（番号の小さい方）が勝つ——マッチの届く順はパターンの
    // 順と限らない。同じパターンが同じ節に重ねて当たれば先に届いた方。
    var claims: [UInt: (pattern: UInt16, node: TSNode, items: [Item])] = [:]
    var order: [UInt] = []
    var annotations: [UInt: Bool] = [:]
    var naming = OutlineItems(grammar: grammar)
    let nodeText: (TSNode) -> String = { node in
      let start = Int(ts_node_start_byte(node)) / 2
      return text.substring(
        NSRange(location: start, length: Int(ts_node_end_byte(node)) / 2 - start))
    }
    let finished = cursor.matches(
      of: query.query, in: tree.root, cancellation: cancellation, text: nodeText
    ) { match in
      let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
      for capture in captures
      where capture.index == query.annotation || capture.index == query.adjacentAnnotation {
        annotations[UInt(bitPattern: capture.node.id)] = capture.index == query.annotation
      }
      guard let kind = query.kinds[Int(match.pattern_index)],
        let item = captures.first(where: { $0.index == query.item })?.node
      else { return }
      let node = UInt(bitPattern: item.id)
      if let claim = claims[node], claim.pattern <= match.pattern_index { return }
      let parts = OutlineMatch(
        item: item, names: captures.filter { $0.index == query.name }.map(\.node),
        contexts: captures.filter { $0.index == query.context }.map(\.node),
        targets: captures.filter { $0.index == query.target }.map(\.node), kind: kind,
        text: nodeText)
      let made = naming.items(for: parts).map { made in
        var made = made
        made.node = node
        return made
      }
      if claims[node] == nil { order.append(node) }
      claims[node] = (match.pattern_index, item, made)
    }
    guard finished else { return nil }
    let items = order.flatMap { node -> [Item] in
      let claim = claims[node]!
      guard !annotations.isEmpty else { return claim.items }
      let start = Self.annotatedStart(of: claim.node, annotations: annotations)
      return claim.items.map { item in
        var item = item
        if start < item.range.location {
          item.range = NSRange(location: start, length: NSMaxRange(item.range) - start)
        }
        return item
      }
    }
    return Self.nest(naming.finish(items, length: text.length), version: version)
  }

  /// `node` の前に続く注釈の頭（UTF-16）。前の兄弟を遡り、注釈の節が続く限り含める。`annotations` は注釈の節 → 空行を
  /// 挟んでも続くか。
  private static func annotatedStart(of node: TSNode, annotations: [UInt: Bool]) -> Int {
    var head = node
    var previous = ts_node_prev_sibling(head)
    while !ts_node_is_null(previous),
      let acrossBlankLines = annotations[UInt(bitPattern: previous.id)]
    {
      if !acrossBlankLines, blankLine(between: previous, and: head) { break }
      head = previous
      previous = ts_node_prev_sibling(head)
    }
    return Int(ts_node_start_byte(head)) / 2
  }

  /// `earlier` の終わりと `later` の頭の間に空行があるか（`earlier` が行末の改行まで含む節でも同じに数える）。
  private static func blankLine(between earlier: TSNode, and later: TSNode) -> Bool {
    let end = ts_node_end_point(earlier)
    let includesBreak = end.column == 0 && ts_node_end_byte(earlier) > ts_node_start_byte(earlier)
    return Int(ts_node_start_point(later).row) - Int(end.row) + (includesBreak ? 1 : 0) >= 2
  }

  /// シンボルの並べ方と親子。`order` は位置順（開始の昇順・終わりの降順）に並べた `items` の番号、`parents` と `ends`
  /// （部分木の終わり）はその並びの上の位置。
  struct Arrangement {
    let order: [Int]
    let parents: [Int?]
    let ends: [Int]
  }

  /// 位置順に並べ、範囲の包含で親子を決める。同じ節から出たシンボルは兄弟。
  static func arrange(_ items: [Item]) -> Arrangement {
    let order = items.indices.sorted { lhs, rhs in
      let a = items[lhs].range
      let b = items[rhs].range
      if a.location != b.location { return a.location < b.location }
      if NSMaxRange(a) != NSMaxRange(b) { return NSMaxRange(a) > NSMaxRange(b) }
      return lhs < rhs
    }
    var parents: [Int?] = []
    var ends = [Int](repeating: order.count, count: order.count)
    var stack: [Int] = []
    for (index, source) in order.enumerated() {
      let item = items[source]
      while let top = stack.last {
        let outer = items[order[top]]
        let contains =
          outer.range.location <= item.range.location
          && NSMaxRange(item.range) <= NSMaxRange(outer.range)
        if contains, outer.node != item.node { break }
        ends[top] = index
        stack.removeLast()
      }
      parents.append(stack.last)
      stack.append(index)
    }
    return Arrangement(order: order, parents: parents, ends: ends)
  }

  /// 位置順に並べ、範囲の包含で入れ子にして鍵を付ける。同じ節から出たシンボルは兄弟。
  static func nest(_ items: [Item], version: Int) -> DocumentOutline {
    let arrangement = arrange(items)
    let order = arrangement.order
    let parents = arrangement.parents
    let ends = arrangement.ends
    var symbols: [OutlineSymbol] = []
    symbols.reserveCapacity(order.count)
    var ordinals: [Int: Int] = [:]
    for (index, source) in order.enumerated() {
      let item = items[source]
      let parent = parents[index]
      var path = Hasher()
      path.combine(parent.map { symbols[$0].key })
      path.combine(item.kind)
      path.combine(item.name)
      let base = path.finalize()
      let ordinal = ordinals[base, default: 0]
      ordinals[base] = ordinal + 1
      var key = Hasher()
      key.combine(base)
      key.combine(ordinal)
      symbols.append(
        OutlineSymbol(
          name: item.name, kind: item.kind, depth: parent.map { symbols[$0].depth + 1 } ?? 0,
          parent: parent, subtreeEnd: ends[index], key: OutlineKey(value: key.finalize())))
    }
    return DocumentOutline(
      version: version, symbols: symbols, ranges: order.map { items[$0].range },
      nameRanges: order.map { items[$0].nameRange })
  }
}

/// マッチ 1 つの、言語の口へ渡す部品。
struct OutlineMatch {
  let item: TSNode
  let names: [TSNode]
  let contexts: [TSNode]
  let targets: [TSNode]
  let kind: OutlineKind
  let text: (TSNode) -> String
}

extension QueryCursor {
  /// `query` を `node` の下で全体にかけ、述語を満たすマッチを順に渡す。打ち切りの印が立てば問い合わせの途中でも止まり、
  /// false を返す。
  func matches(
    of query: SyntaxQuery, in node: TSNode, cancellation: SyntaxCancellation,
    text: (TSNode) -> String, each body: (TSQueryMatch) -> Void
  ) -> Bool {
    ts_query_cursor_set_byte_range(raw, 0, UInt32.max)
    ts_query_cursor_set_containing_byte_range(raw, 0, 0)
    // cursor は問い合わせの間ずっと options を指すので、options はマッチを読み終えるまで同じ場所に置く。
    var options = TSQueryCursorOptions(
      payload: Unmanaged.passUnretained(cancellation).toOpaque(),
      progress_callback: queryCancelled)
    withExtendedLifetime(cancellation) {
      withUnsafePointer(to: &options) { options in
        ts_query_cursor_exec_with_options(raw, query.raw, node, options)
        var match = TSQueryMatch()
        while !cancellation.isCancelled, ts_query_cursor_next_match(raw, &match) {
          if query.accepts(match, text: text) { body(match) }
        }
      }
    }
    return !cancellation.isCancelled
  }
}

private let queryCancelled: @convention(c) (UnsafeMutablePointer<TSQueryCursorState>?) -> Bool =
  { state in
    Unmanaged<SyntaxCancellation>.fromOpaque(state!.pointee.payload!).takeUnretainedValue()
      .isCancelled
  }
