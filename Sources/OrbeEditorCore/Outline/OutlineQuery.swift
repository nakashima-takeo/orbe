import Foundation
import TreeSitter

/// outline の問い合わせ（Orbe の規則 `outline/<文法>.scm`）。capture は `@item`（シンボルの節）・`@name`（名前）・
/// `@context`（名前の前に付ける字）、種類はパターンごとの `#set! kind`。種類の無いパターンは何も出さない。
final class OutlineQuery: Sendable {
  let query: SyntaxQuery
  let item: UInt32
  let name: UInt32?
  let context: UInt32?
  /// パターンごとの種類。
  let kinds: [OutlineKind?]

  /// `@item` が無ければ nil。
  init?(_ query: SyntaxQuery) {
    guard let item = query.captureNames.firstIndex(of: "item") else { return nil }
    self.query = query
    self.item = UInt32(item)
    name = query.captureNames.firstIndex(of: "name").map { UInt32($0) }
    context = query.captureNames.firstIndex(of: "context").map { UInt32($0) }
    kinds = query.settings.map { $0["kind"].flatMap(OutlineKind.init(rawValue:)) }
  }
}

/// 根の構文木 1 本からアウトラインを取り出す。問い合わせを木全体に 1 回かけ、マッチごとに言語の口（`OutlineItems`）で
/// シンボルを作り、`@item` の節の範囲の包含で入れ子にする。cursor を持つので、使う裏の仕事の中だけで使う。
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
    var claims: [UInt: (pattern: UInt16, items: [Item])] = [:]
    var order: [UInt] = []
    let nodeText: (TSNode) -> String = { node in
      let start = Int(ts_node_start_byte(node)) / 2
      return text.substring(
        NSRange(location: start, length: Int(ts_node_end_byte(node)) / 2 - start))
    }
    let finished = cursor.matches(
      of: query.query, in: tree.root, cancellation: cancellation, text: nodeText
    ) { match in
      guard let kind = query.kinds[Int(match.pattern_index)] else { return }
      let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
      guard let item = captures.first(where: { $0.index == query.item })?.node else { return }
      let node = UInt(bitPattern: item.id)
      if let claim = claims[node], claim.pattern <= match.pattern_index { return }
      let parts = OutlineMatch(
        item: item, names: captures.filter { $0.index == query.name }.map(\.node),
        contexts: captures.filter { $0.index == query.context }.map(\.node), kind: kind,
        text: nodeText)
      let made = OutlineItems.items(for: grammar, parts).map { made in
        var made = made
        made.node = node
        return made
      }
      if claims[node] == nil { order.append(node) }
      claims[node] = (match.pattern_index, made)
    }
    guard finished else { return nil }
    return Self.nest(order.flatMap { claims[$0]!.items }, version: version)
  }

  /// 位置順（開始の昇順・終わりの降順）に並べ、範囲の包含で入れ子にして鍵を付ける。同じ節から出たシンボルは兄弟。
  static func nest(_ items: [Item], version: Int) -> DocumentOutline {
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
    var symbols: [OutlineSymbol] = []
    symbols.reserveCapacity(order.count)
    var ordinals: [String: Int] = [:]
    for (index, source) in order.enumerated() {
      let item = items[source]
      let parent = parents[index]
      let base =
        (parent.map { symbols[$0].key.path } ?? "") + "\u{1F}" + item.kind.rawValue + "\u{1E}"
        + item.name
      let ordinal = ordinals[base, default: 0]
      ordinals[base] = ordinal + 1
      symbols.append(
        OutlineSymbol(
          name: item.name, kind: item.kind, depth: parent.map { symbols[$0].depth + 1 } ?? 0,
          parent: parent, subtreeEnd: ends[index],
          key: OutlineKey(path: ordinal == 0 ? base : base + "\u{1D}\(ordinal)")))
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
