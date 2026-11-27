import Foundation

/// 折り返した行——2 段目からの段の始まり（描く単位の位置。昇順）と、続きの段の字下げ（pt）。段の始まりが描く単位の数と
/// 同じなら、その段は打ち切った行の末尾の印だけを持つ。
public struct WrappedLine: Equatable, Sendable {
  public var starts: [Int32]
  public var indent: Float
  /// 最後の段より前の各段について、その段の終わりを決めるために読んだ、描く単位の区間の終わり（その位置を含まない）。
  /// これより後ろだけを変えた編集では、その段の終わりは変わらない（→ `LineWrap.Resume`）。
  public var ends: [Int32]

  public init(starts: [Int32], indent: Float, ends: [Int32]) {
    self.starts = starts
    self.indent = indent
    self.ends = ends
  }

  /// 段の数。
  public var segments: Int { starts.count + 1 }

  /// 段 `segment` の始まり（描く単位の位置）。
  public func start(of segment: Int) -> Int { segment == 0 ? 0 : Int(starts[segment - 1]) }

  /// 位置 `column`（描く単位）を含む段。段の境の位置は、`upstream`（付き）なら上の段の終わり、そうでなければ下の段の頭。
  public func segment(containing column: Int, upstream: Bool = false) -> Int {
    var low = 0
    var high = starts.count
    while low < high {
      let mid = (low + high) / 2
      let start = Int(starts[mid])
      if start < column || (start == column && !upstream) { low = mid + 1 } else { high = mid }
    }
    return low
  }
}

/// 行ごとの折り返し——文書の行ごとの段の始まりと続きの段の字下げを、要約つきの木に載せたもの。木の要素は、折り返した行 1 つか、
/// 1 段の行が続く範囲 1 つ（何行続いても要素 1 つにまとめるので、コードの文書では木は小さいまま）。値として写せて、別の
/// スレッドから読める。行と段の行き来は木の深さに比例する。木（`SummaryTree`）と同じモジュールに置く——木の操作が要素の
/// 型に特殊化される（他のモジュールから使うと、特殊化されない汎用の経路で走り、探索と置き換えが数倍遅い）。
public struct LineWraps: Sendable {
  /// 木の要素の中身——折り返した行 1 つか、1 段の行が続く数。
  enum Kind: Sendable {
    case wrapped(WrappedLine)
    case plain(Int)
  }

  /// 木の要素。
  struct Element: TreeElement, Sendable {
    let kind: Kind
    let summary: Summary

    init(_ kind: Kind) {
      self.kind = kind
      switch kind {
      case .wrapped(let line): summary = Summary(lines: 1, segments: line.segments)
      case .plain(let count): summary = Summary(lines: count, segments: count)
      }
    }
  }

  /// 要素の要約——文書の行の数と段の数。
  struct Summary: TreeSummary {
    var lines: Int
    var segments: Int

    static let zero = Summary(lines: 0, segments: 0)

    static func + (lhs: Summary, rhs: Summary) -> Summary {
      Summary(lines: lhs.lines + rhs.lines, segments: lhs.segments + rhs.segments)
    }
  }

  /// 計算に使った折り返しの幅とタブの刻み（pt）。
  public let width: Double
  public let tabWidth: Double
  /// 計算に使った本文の写しの版。
  public var version: Int
  private(set) var tree: SummaryTree<Element>

  /// 本文の写しの版 `version` の、行ごとの折り返し `lines`（1 段の行は nil）から組む。
  public init(width: Double, tabWidth: Double, version: Int, lines: [WrappedLine?]) {
    self.width = width
    self.tabWidth = tabWidth
    self.version = version
    tree = SummaryTree(Self.elements(lines))
  }

  /// 文書の行の数と、段の合計。
  public var lineCount: Int { tree.summary.lines }
  public var segmentCount: Int { tree.summary.segments }

  /// 文書の行 `line` より上の段の数。行の数より後ろの行は、1 行を 1 段として数え足す（負の行はそのまま）。
  public func segments(before line: Int) -> Int {
    guard line > 0 else { return line }
    guard line < lineCount else { return segmentCount + line - lineCount }
    let (index, before) = tree.locate(line, by: \.lines)
    if case .plain = tree[index].kind { return before.segments + line - before.lines }
    return before.segments
  }

  /// 文書の行 `line` の折り返し（1 段の行と、文書の行の外なら nil）。
  public func wrap(ofLine line: Int) -> WrappedLine? {
    guard line >= 0, line < lineCount else { return nil }
    let (index, _) = tree.locate(line, by: \.lines)
    if case .wrapped(let wrapped) = tree[index].kind { return wrapped }
    return nil
  }

  /// 上から `segment` 番目の段（0 始まり）の文書の行と、その行の中の段。段の合計より後ろは、1 段を 1 行として数え足した
  /// 行の段 0（負の段は、その数の行の段 0）。
  public func line(atSegment segment: Int) -> (line: Int, segment: Int) {
    guard segment >= 0 else { return (segment, 0) }
    guard segment < segmentCount else { return (lineCount + segment - segmentCount, 0) }
    let (index, before) = tree.locate(segment, by: \.segments)
    switch tree[index].kind {
    case .plain: return (before.lines + segment - before.segments, 0)
    case .wrapped: return (before.lines, segment - before.segments)
    }
  }

  /// 文書の行の区間 `lines` を、行ごとの折り返し `replacement`（1 段の行は nil）に置き換える（行の数が変わってよい）。前後に
  /// 続く 1 段の行の要素は、置き換えた要素と 1 つにまとめる——打鍵のたびに、1 段の行の続きが細かく割れていかない。
  public mutating func replace(_ lines: Range<Int>, with replacement: [WrappedLine?]) {
    precondition(lines.lowerBound >= 0 && lines.upperBound <= lineCount, "行の区間が木の外")
    let (low, high) = (lines.lowerBound, lines.upperBound)
    var first = low < lineCount ? tree.locate(low, by: \.lines).index : tree.count
    var end = high > low ? tree.locate(high - 1, by: \.lines).index + 1 : first
    if end == first, first < tree.count, low > tree.prefix(upTo: first).lines { end += 1 }
    if first > 0, isPlain(first - 1) { first -= 1 }
    if end < tree.count, isPlain(end) { end += 1 }
    let head = low - tree.prefix(upTo: first).lines
    let tail = (end < tree.count ? tree.prefix(upTo: end).lines : lineCount) - high
    var builder = Builder()
    builder.append(plain: head)
    for line in replacement { builder.append(line) }
    builder.append(plain: tail)
    tree.replaceSubrange(first..<end, with: builder.elements)
  }

  /// 置き換えの列 `edits`（文書の行の区間は今の木の行で、昇順で重ならない）をまとめて当てる。区間の数が要素の数に比べて
  /// 多ければ（複数カーソルの打鍵）、要素を前から 1 度だけ読んで木を組み直す——区間ごとの置き換えは、1 区間ごとに木の
  /// 経路を写す。区間が少なければ、区間ごとに置き換える（組み直しは要素の数に比例する）。
  public mutating func replace(_ edits: [(lines: Range<Int>, with: [WrappedLine?])]) {
    guard !edits.isEmpty else { return }
    guard edits.count * 64 >= tree.count else {
      for edit in edits.reversed() { replace(edit.lines, with: edit.with) }
      return
    }
    var builder = Builder()
    var reader = Reader(tree.elements(from: 0))
    var line = 0
    for edit in edits {
      reader.take(edit.lines.lowerBound - line, into: &builder)
      reader.skip(edit.lines.count)
      for wrapped in edit.with { builder.append(wrapped) }
      line = edit.lines.upperBound
    }
    reader.take(lineCount - line, into: &builder)
    tree = SummaryTree(builder.elements)
  }

  private func isPlain(_ index: Int) -> Bool {
    if case .plain = tree[index].kind { return true }
    return false
  }

  /// 行ごとの折り返しの列を、1 段の行の続きをまとめた要素の列にする。
  private static func elements(_ lines: some Collection<WrappedLine?>) -> [Element] {
    var builder = Builder()
    for line in lines { builder.append(line) }
    return builder.elements
  }

  /// 要素の列を組む。1 段の行（折り返さない行）は数だけで足し、隣り合う 1 段の行を要素 1 つにまとめる——1 段の行が何万行
  /// 続く所に掛かる置き換えでも、手間は置き換える行の数で決まる。
  private struct Builder {
    private var done: [Element] = []
    private var plain = 0

    mutating func append(plain count: Int) { plain += count }

    mutating func append(_ line: WrappedLine?) {
      guard let line else { return plain += 1 }
      flush()
      done.append(Element(.wrapped(line)))
    }

    private mutating func flush() {
      if plain > 0 { done.append(Element(.plain(plain))) }
      plain = 0
    }

    var elements: [Element] {
      mutating get {
        flush()
        return done
      }
    }
  }

  /// 木の要素を前から行の数で読む（1 段の行の続きは途中で切って読める）。
  private struct Reader {
    private var iterator: SummaryTree<Element>.Elements
    private var current: Kind?
    private var left = 0

    init(_ iterator: SummaryTree<Element>.Elements) { self.iterator = iterator }

    /// 次の `count` 行を `builder` へ写す。
    mutating func take(_ count: Int, into builder: inout Builder) {
      read(count, into: &builder, copies: true)
    }

    /// 次の `count` 行を読み飛ばす。
    mutating func skip(_ count: Int) {
      var unused = Builder()
      read(count, into: &unused, copies: false)
    }

    private mutating func read(_ count: Int, into builder: inout Builder, copies: Bool) {
      var count = count
      while count > 0 {
        if left == 0 {
          guard let element = iterator.next() else { return }
          current = element.kind
          left = element.summary.lines
        }
        let taken = min(count, left)
        if copies {
          switch current {
          case .wrapped(let line): builder.append(line)
          case .plain: builder.append(plain: taken)
          case nil: break
          }
        }
        left -= taken
        count -= taken
      }
    }
  }
}
