import Foundation

/// 本文の写し（UTF-16）。本文を 1KB 程度の塊に分けて要約付きの B 木（`SummaryTree`）に載せ、塊ごとに UTF-16 の長さと
/// 改行の数を束ねる。行とオフセットの変換・部分の取り出し・置換は文書の大きさに依らない（O(log n + k)）。値として写すのは
/// O(1) で、写しは変わらないので、裏のスレッドがロックも複製も無しで読める。
///
/// 行は `\n` だけで割る。CRLF の `\r` は行の中身に残り、単独の `\r`・U+2028・U+2029 は行を割らない（tree-sitter・行差分と
/// 同じ数え方）。本文が改行で終わるなら、末尾の空行も 1 行。
public struct TextRope: Sendable {
  /// 塊の大きさの目安（UTF-16 単位）。置換で小さくなった塊は隣と合わせる。
  static let maximumChunk = 1024
  static let minimumChunk = 512

  public struct Summary: TreeSummary {
    public var utf16: Int
    public var newlines: Int

    public static let zero = Summary(utf16: 0, newlines: 0)

    public static func + (lhs: Summary, rhs: Summary) -> Summary {
      Summary(utf16: lhs.utf16 + rhs.utf16, newlines: lhs.newlines + rhs.newlines)
    }
  }

  struct Chunk: TreeElement {
    let units: ContiguousArray<UInt16>
    let summary: Summary

    init(_ units: ContiguousArray<UInt16>) {
      self.units = units
      summary = Summary(utf16: units.count, newlines: units.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) })
    }
  }

  private var chunks: SummaryTree<Chunk>

  public init(_ string: String = "") {
    chunks = SummaryTree(Self.chunked(ContiguousArray(string.utf16)[...]))
  }

  /// 本文の UTF-16 長。
  public var length: Int { chunks.summary.utf16 }

  /// 行の数（本文が改行で終わるときの末尾の空行を含む）。
  public var lineCount: Int { chunks.summary.newlines + 1 }

  /// 0 始まりの行の先頭オフセット。行の数を越える行は本文の長さ。
  public func lineStart(_ row: Int) -> Int {
    guard row > 0 else { return 0 }
    guard row < lineCount else { return length }
    let (index, before) = chunks.locate(row - 1, by: \.newlines)
    var remaining = row - before.newlines
    for (position, unit) in chunks[index].units.enumerated() where unit == 0x0A {
      remaining -= 1
      if remaining == 0 { return before.utf16 + position + 1 }
    }
    return length
  }

  /// 0 始まりの行の終わり（次の行頭。最後の行なら本文の長さ）。
  public func lineEnd(_ row: Int) -> Int {
    row + 1 < lineCount ? lineStart(row + 1) : length
  }

  /// オフセットを含む行（その前にある `\n` の数）。
  public func row(containing offset: Int) -> Int {
    let offset = min(max(0, offset), length)
    guard let (index, before) = chunk(containing: offset) else { return 0 }
    let local = offset - before.utf16
    return before.newlines + chunks[index].units[..<local].reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
  }

  /// オフセットが属する行と、行頭からの距離（UTF-16 単位）。
  public func point(at offset: Int) -> (row: Int, column: Int) {
    let row = row(containing: offset)
    return (row, offset - lineStart(row))
  }

  /// 区間の行（0 始まり・両端を含む）。空の区間はその位置の行 1 つ。
  public func rows(of range: NSRange) -> ClosedRange<Int> {
    let first = row(containing: range.location)
    let last = range.length > 0 ? row(containing: NSMaxRange(range) - 1) : first
    return first...max(first, last)
  }

  /// 昇順で重ならない区間の列それぞれの行（`rows(of:)` と同じ答え）。塊を前から 1 度だけ辿り、区間の無い塊は改行数の
  /// 要約で読み飛ばす（O(辿る塊 + 区間の数)）——検索の一致（上限 2 万件）を描画のたびに行へ写すため。
  public func rows(ofAscending ranges: [NSRange]) -> [ClosedRange<Int>] {
    guard let first = ranges.first else { return [] }
    var cursor = RowCursor(self, from: first.location)
    return ranges.map { range in
      let start = cursor.row(at: range.location)
      let last = range.length > 0 ? cursor.row(at: NSMaxRange(range) - 1) : start
      return start...max(start, last)
    }
  }

  /// 減らないオフセットの列の行を、塊を前から辿って出す。
  private struct RowCursor {
    private var chunks: SummaryTree<Chunk>.Elements
    private var current: Chunk?
    /// 今の塊の先頭のオフセットと、その前の改行の数。
    private var chunkStart = 0
    private var newlinesBefore = 0
    /// 今の塊の中で数え終えた単位の数と、その中の改行の数。
    private var scanned = 0
    private var newlinesScanned = 0

    init(_ rope: TextRope, from offset: Int) {
      guard let (index, before) = rope.chunk(containing: min(max(0, offset), rope.length)) else {
        chunks = rope.chunks.elements(from: 0)
        return
      }
      chunks = rope.chunks.elements(from: index)
      current = chunks.next()
      chunkStart = before.utf16
      newlinesBefore = before.newlines
    }

    mutating func row(at offset: Int) -> Int {
      guard var chunk = current else { return 0 }
      while offset >= chunkStart + chunk.units.count, let next = chunks.next() {
        newlinesBefore += chunk.summary.newlines
        chunkStart += chunk.units.count
        chunk = next
        scanned = 0
        newlinesScanned = 0
      }
      current = chunk
      let local = min(max(0, offset - chunkStart), chunk.units.count)
      while scanned < local {
        if chunk.units[scanned] == 0x0A { newlinesScanned += 1 }
        scanned += 1
      }
      return newlinesBefore + newlinesScanned
    }
  }

  /// 区間の UTF-16 単位（本文の外は切り詰める）。
  public func units(in range: NSRange) -> ContiguousArray<UInt16> {
    let start = min(max(0, range.location), length)
    let end = min(max(start, NSMaxRange(range)), length)
    var result = ContiguousArray<UInt16>()
    guard start < end, let (index, before) = chunk(containing: start) else { return result }
    result.reserveCapacity(end - start)
    var chunkStart = before.utf16
    for chunk in chunks.elements(from: index) {
      let from = max(start - chunkStart, 0)
      let to = min(end - chunkStart, chunk.units.count)
      result.append(contentsOf: chunk.units[from..<to])
      chunkStart += chunk.units.count
      if chunkStart >= end { break }
    }
    return result
  }

  /// 区間の文字列。単独のサロゲートもそのまま保つ（NSString と同じ）。
  public func substring(_ range: NSRange) -> String {
    let units = units(in: range)
    return units.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress else { return "" }
      return String(utf16CodeUnits: base, count: buffer.count)
    }
  }

  /// `offset` から、それを含む塊の終わりまでの UTF-16LE のバイト列（tree-sitter の読み口）。本文の終わりなら nil。
  public func chunkData(at offset: Int) -> Data? {
    guard offset >= 0, offset < length, let (index, before) = chunk(containing: offset) else {
      return nil
    }
    return chunks[index].units[(offset - before.utf16)...].withUnsafeBufferPointer {
      Data(buffer: $0)
    }
  }

  /// 本文全体を連続した UTF-16 の列に写す（O(n)）。打鍵の経路では呼ばない——使うのは裏の仕事（検索・出現・行差分）と
  /// 保存。
  public func contiguousUnits() -> ContiguousArray<UInt16> {
    var result = ContiguousArray<UInt16>()
    result.reserveCapacity(length)
    for chunk in chunks.elements(from: 0) { result.append(contentsOf: chunk.units) }
    return result
  }

  /// 保存する UTF-8 のバイト列（単独のサロゲートは U+FFFD）。
  public func utf8Data() -> Data {
    Data(String(decoding: contiguousUnits(), as: UTF16.self).utf8)
  }

  /// 本文の UTF-16 単位を先頭から読む（塊を順に辿る）。
  public var utf16: UTF16View { UTF16View(chunks: chunks.elements(from: 0)) }

  public struct UTF16View: Sequence, IteratorProtocol {
    fileprivate var chunks: SummaryTree<Chunk>.Elements
    private var current = ContiguousArray<UInt16>()
    private var position = 0

    fileprivate init(chunks: SummaryTree<Chunk>.Elements) {
      self.chunks = chunks
    }

    public mutating func next() -> UInt16? {
      while position == current.count {
        guard let chunk = chunks.next() else { return nil }
        current = chunk.units
        position = 0
      }
      defer { position += 1 }
      return current[position]
    }
  }

  /// 区間を置き換える。置き換える区間に掛かる塊だけを組み直し、小さくなりすぎた塊は隣と合わせる。
  public mutating func replace(_ range: NSRange, with replacement: String) {
    replace(range, with: ContiguousArray(replacement.utf16))
  }

  /// 区間を UTF-16 の単位の列で置き換える（サロゲートの対の片割れもそのまま持つ）。
  public mutating func replace(_ range: NSRange, with inserted: ContiguousArray<UInt16>) {
    let start = min(max(0, range.location), length)
    let end = min(max(start, NSMaxRange(range)), length)
    guard let (first, firstBefore) = chunk(containing: start) else {
      chunks = SummaryTree(Self.chunked(inserted[...]))
      return
    }
    let (last, lastBefore) = end > start ? chunk(containing: end - 1)! : (first, firstBefore)
    var lower = first
    var upper = last
    var units = ContiguousArray(chunks[first].units[..<(start - firstBefore.utf16)])
    units.append(contentsOf: inserted)
    units.append(contentsOf: chunks[last].units[(end - lastBefore.utf16)...])
    if units.count < Self.minimumChunk {
      if upper + 1 < chunks.count {
        upper += 1
        units.append(contentsOf: chunks[upper].units)
      } else if lower > 0 {
        lower -= 1
        units.insert(contentsOf: chunks[lower].units, at: 0)
      }
    }
    chunks.replaceSubrange(lower..<(upper + 1), with: Self.chunked(units[...]))
  }

  /// オフセットを含む塊（本文の終わりなら最後の塊）と、その前の要約。本文が空なら nil。
  private func chunk(containing offset: Int) -> (Int, Summary)? {
    guard !chunks.isEmpty else { return nil }
    guard offset < length else {
      let index = chunks.count - 1
      return (index, chunks.prefix(upTo: index))
    }
    return chunks.locate(max(0, offset), by: \.utf16)
  }

  /// 単位の列を、大きさを揃えた `maximumChunk` 以下の塊に分ける。サロゲートの対は塊の境で割らず、そのときだけ塊が
  /// 1 単位超える。
  private static func chunked(_ units: ArraySlice<UInt16>) -> [Chunk] {
    guard !units.isEmpty else { return [] }
    let parts = (units.count + maximumChunk - 1) / maximumChunk
    var result: [Chunk] = []
    result.reserveCapacity(parts)
    var start = units.startIndex
    for part in 1...parts {
      var cut = units.startIndex + units.count * part / parts
      if cut < units.endIndex, UTF16.isLeadSurrogate(units[cut - 1]),
        UTF16.isTrailSurrogate(units[cut])
      {
        cut += 1
      }
      guard cut > start else { continue }
      result.append(Chunk(ContiguousArray(units[start..<cut])))
      start = cut
    }
    return result
  }
}
