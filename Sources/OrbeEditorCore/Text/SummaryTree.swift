/// 和を取れる要約（ゼロと加算）。木の節は子の要約の和を持ち、位置の探索は要約の成分で節を下る。
public protocol TreeSummary: Sendable, Equatable {
  static var zero: Self { get }
  static func + (lhs: Self, rhs: Self) -> Self
}

extension TreeSummary {
  static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
}

/// 木に載せる要素。要素ごとに要約を持つ。
public protocol TreeElement: Sendable {
  associatedtype Summary: TreeSummary
  var summary: Summary { get }
}

/// 要約付きの B 木。葉は要素の列、節は子の列と要約の和を持つ。値として写すのは O(1) で、変更は根から葉までの経路だけを
/// 写す——写しは変わらないので、別のスレッドへ渡してロックなしで読める。すべての葉は同じ深さにあり、根を除く節の子（葉の
/// 要素）の数は `minimumFanout...maximumFanout`。
public struct SummaryTree<Element: TreeElement>: Sendable {
  public typealias Summary = Element.Summary

  static var maximumFanout: Int { 16 }
  static var minimumFanout: Int { 8 }

  private var root: Node

  public init() {
    root = Node(elements: [])
  }

  public init(_ elements: some Collection<Element>) {
    root = Self.build(Array(elements))
  }

  private init(root: Node) {
    self.root = root
  }

  public var summary: Summary { root.summary }
  /// 要素の数。
  public var count: Int { root.count }
  public var isEmpty: Bool { root.count == 0 }

  /// `index` 番目の要素（O(log n)）。
  public subscript(index: Int) -> Element {
    var node = root
    var index = index
    while node.height > 0 {
      for child in node.children {
        if index < child.count {
          node = child
          break
        }
        index -= child.count
      }
    }
    return node.elements[index]
  }

  /// 成分 `metric` で `position` を含む要素——`metric` の累積が初めて `position` を超える要素の番号と、その前の要素の
  /// 要約の和。`position` が全体の和以上なら（`count`、全体の和）。`metric` は要約の単調な成分であること。
  public func locate(_ position: Int, by metric: (Summary) -> Int) -> (index: Int, before: Summary)
  {
    guard position < metric(root.summary) else { return (root.count, root.summary) }
    var node = root
    var index = 0
    var before = Summary.zero
    while node.height > 0 {
      for child in node.children {
        let through = before + child.summary
        if metric(through) > position {
          node = child
          break
        }
        before = through
        index += child.count
      }
    }
    for element in node.elements {
      let through = before + element.summary
      if metric(through) > position { break }
      before = through
      index += 1
    }
    return (index, before)
  }

  /// `index` 番目より前の要素の要約の和。
  public func prefix(upTo index: Int) -> Summary {
    guard index < root.count else { return root.summary }
    var node = root
    var index = index
    var before = Summary.zero
    while node.height > 0 {
      for child in node.children {
        if index < child.count {
          node = child
          break
        }
        before += child.summary
        index -= child.count
      }
    }
    for element in node.elements[..<index] { before += element.summary }
    return before
  }

  /// `index` 番目から前向きに要素を読む（1 要素あたり償却 O(1)）。
  public func elements(from index: Int) -> Elements {
    Elements(root: root, from: index)
  }

  /// 要素の区間を置き換える。区間が 1 つの葉の中に収まり、置き換えた葉の要素の数が範囲に収まるときは、その葉までの経路を
  /// 写すだけで済む（打鍵の多く）。それ以外は切り分けて繋ぎ直す（O(log n + k)）。
  public mutating func replaceSubrange(_ range: Range<Int>, with elements: some Collection<Element>)
  {
    precondition(range.lowerBound >= 0 && range.upperBound <= root.count, "区間が木の外")
    let new = Array(elements)
    if Self.fitsInLeaf(root, range, adding: new.count, isRoot: true) {
      Self.splice(&root, range, new)
      return
    }
    var result = Self.slice(root, 0..<range.lowerBound)
    if !new.isEmpty { result = Self.concat(result, Self.build(new)) }
    result = Self.concat(result, Self.slice(root, range.upperBound..<root.count))
    root = Self.normalized(result)
  }

  public mutating func append(contentsOf elements: some Collection<Element>) {
    replaceSubrange(count..<count, with: elements)
  }

  // MARK: - 節

  /// 木の節。不変条件: 共有されている節（参照が 2 つ以上）は変更しない——変更は `isKnownUniquelyReferenced` で一意と
  /// 確かめた節か、作ったばかりの節にだけ行う。これで、値として写した木（別のスレッドへ渡した写しを含む）から見える節は
  /// 決して変わらず、ロックなしで読める。コンパイラはこの規律を見られないので `@unchecked Sendable` とする。
  final class Node: @unchecked Sendable {
    /// 葉は 0。
    let height: Int
    private(set) var count: Int
    private(set) var summary: Summary
    var children: [Node]
    var elements: [Element]

    init(elements: [Element]) {
      height = 0
      self.elements = elements
      children = []
      count = elements.count
      summary = elements.reduce(.zero) { $0 + $1.summary }
    }

    init(children: [Node]) {
      height = children[0].height + 1
      self.children = children
      elements = []
      count = children.reduce(0) { $0 + $1.count }
      summary = children.reduce(.zero) { $0 + $1.summary }
    }

    private init(copying node: Node) {
      height = node.height
      count = node.count
      summary = node.summary
      children = node.children
      elements = node.elements
    }

    func copy() -> Node { Node(copying: self) }

    /// 子（葉なら要素）の数。
    var fanout: Int { height == 0 ? elements.count : children.count }

    /// 根でない位置に置いてよい大きさか。
    var isValidChild: Bool { fanout >= SummaryTree.minimumFanout }

    /// 子（要素）を変えた後に、数と要約を出し直す。
    func recompute() {
      if height == 0 {
        count = elements.count
        summary = elements.reduce(.zero) { $0 + $1.summary }
      } else {
        count = children.reduce(0) { $0 + $1.count }
        summary = children.reduce(.zero) { $0 + $1.summary }
      }
    }
  }

  // MARK: - 経路を写す変更

  /// 区間（空なら挿入位置）が 1 つの葉に収まり、置き換えた葉の要素の数が範囲に収まるか。
  private static func fitsInLeaf(_ node: Node, _ range: Range<Int>, adding: Int, isRoot: Bool)
    -> Bool
  {
    if node.height == 0 {
      let size = node.elements.count - range.count + adding
      return size <= maximumFanout && (isRoot || size >= minimumFanout)
    }
    guard let (child, local) = child(of: node, containing: range) else { return false }
    return fitsInLeaf(node.children[child], local, adding: adding, isRoot: false)
  }

  private static func splice(_ node: inout Node, _ range: Range<Int>, _ new: [Element]) {
    if !isKnownUniquelyReferenced(&node) { node = node.copy() }
    if node.height == 0 {
      node.elements.replaceSubrange(range, with: new)
    } else {
      let (child, local) = child(of: node, containing: range)!
      splice(&node.children[child], local, new)
    }
    node.recompute()
  }

  /// 区間を丸ごと含む子の番号と、子の中での区間。空の区間は、その位置で終わる子より始まる子を選ぶ（末尾なら最後の子）。
  private static func child(of node: Node, containing range: Range<Int>) -> (Int, Range<Int>)? {
    var start = 0
    for (index, child) in node.children.enumerated() {
      let end = start + child.count
      let isLast = index == node.children.count - 1
      if range.lowerBound < end || (isLast && range.lowerBound == end) {
        guard range.upperBound <= end else { return nil }
        return (index, (range.lowerBound - start)..<(range.upperBound - start))
      }
      start = end
    }
    return nil
  }

  // MARK: - 切り分けと連結

  /// 要素の列から釣り合った木を組む。
  private static func build(_ elements: [Element]) -> Node {
    var level = split(elements).map { Node(elements: Array($0)) }
    while level.count > 1 {
      level = split(level).map { Node(children: Array($0)) }
    }
    return level.first ?? Node(elements: [])
  }

  /// 列を `maximumFanout` 以下の塊に、大きさを揃えて分ける（2 つ以上に分けるなら、どれも `minimumFanout` 以上）。
  private static func split<T>(_ items: [T]) -> [ArraySlice<T>] {
    guard items.count > maximumFanout else { return [items[...]] }
    let parts = (items.count + maximumFanout - 1) / maximumFanout
    return (0..<parts).map { part in
      items[(items.count * part / parts)..<(items.count * (part + 1) / parts)]
    }
  }

  /// 要素の区間の部分木（区間を丸ごと覆う節はそのまま共有する）。
  private static func slice(_ node: Node, _ range: Range<Int>) -> Node {
    if range.isEmpty { return Node(elements: []) }
    if range.lowerBound == 0 && range.upperBound == node.count { return node }
    if node.height == 0 { return Node(elements: Array(node.elements[range])) }
    var result: Node?
    var start = 0
    for child in node.children {
      let end = start + child.count
      if end > range.lowerBound && start < range.upperBound {
        let part = slice(
          child, (max(range.lowerBound, start) - start)..<(min(range.upperBound, end) - start))
        result = result.map { concat($0, part) } ?? part
      }
      start = end
    }
    return result ?? Node(elements: [])
  }

  /// 2 つの木を繋ぐ（高さの差に比例する）。xi-rope の `Node::concat` と同じ手順。
  private static func concat(_ left: Node, _ right: Node) -> Node {
    if left.count == 0 { return right }
    if right.count == 0 { return left }
    if left.height < right.height {
      let first = right.children[0]
      if left.height == right.height - 1 && left.isValidChild {
        return merge([left], Array(right.children))
      }
      let joined = concat(left, first)
      let rest = Array(right.children.dropFirst())
      return joined.height == right.height - 1
        ? merge([joined], rest) : merge(joined.children, rest)
    }
    if left.height > right.height {
      let last = left.children[left.children.count - 1]
      if right.height == left.height - 1 && right.isValidChild {
        return merge(Array(left.children), [right])
      }
      let joined = concat(last, right)
      let rest = Array(left.children.dropLast())
      return joined.height == left.height - 1 ? merge(rest, [joined]) : merge(rest, joined.children)
    }
    if left.isValidChild && right.isValidChild { return Node(children: [left, right]) }
    if left.height == 0 { return mergeLeaves(left.elements + right.elements) }
    return merge(Array(left.children), Array(right.children))
  }

  /// 同じ高さの子の列を 1 つ（収まらなければ 2 つに分けて親を立てた）節にする。
  private static func merge(_ left: [Node], _ right: [Node]) -> Node {
    let children = left + right
    guard children.count > maximumFanout else { return Node(children: children) }
    let cut = min(maximumFanout, children.count - minimumFanout)
    return Node(children: [
      Node(children: Array(children[..<cut])), Node(children: Array(children[cut...])),
    ])
  }

  private static func mergeLeaves(_ elements: [Element]) -> Node {
    guard elements.count > maximumFanout else { return Node(elements: elements) }
    let cut = elements.count / 2
    return Node(children: [
      Node(elements: Array(elements[..<cut])), Node(elements: Array(elements[cut...])),
    ])
  }

  /// 子が 1 つだけの根を畳む。
  private static func normalized(_ node: Node) -> Node {
    var node = node
    while node.height > 0 && node.children.count == 1 { node = node.children[0] }
    return node
  }

  // MARK: - 前向きの読み

  /// 葉までの経路を積んで、要素を前向きに返す。
  public struct Elements: Sequence, IteratorProtocol {
    private var stack: [(node: Node, next: Int)] = []

    fileprivate init(root: Node, from index: Int) {
      guard index < root.count else { return }
      var node = root
      var index = index
      while node.height > 0 {
        for (position, child) in node.children.enumerated() {
          if index < child.count {
            stack.append((node, position + 1))
            node = child
            break
          }
          index -= child.count
        }
      }
      stack.append((node, index))
    }

    public mutating func next() -> Element? {
      while let top = stack.last {
        if top.node.height == 0 {
          if top.next < top.node.elements.count {
            stack[stack.count - 1].next += 1
            return top.node.elements[top.next]
          }
        } else if top.next < top.node.children.count {
          stack[stack.count - 1].next += 1
          var node = top.node.children[top.next]
          while node.height > 0 {
            stack.append((node, 1))
            node = node.children[0]
          }
          stack.append((node, 0))
          continue
        }
        stack.removeLast()
      }
      return nil
    }
  }
}
