import Foundation
import TreeSitter

/// 構文の層 1 つ。根の層は本文全体を、注入の層は注入の範囲だけを解く。構文木は層の原点を 0 とする座標で持つ。
final class SyntaxLayer {
  let rules: GrammarRules
  let depth: Int
  /// 注入を生んだ層（根は nil）。
  let parent: SyntaxLayer?
  /// 規則が束ねると指定した注入を、（生んだ層・言語）ごとに 1 本に束ねた層。原点は本文の先頭。
  let isCombined: Bool
  /// マッチごとの、マッチの範囲と注入の範囲（層の座標）。根は空、束ねない層は 1 つ。
  var parts: [InjectionPart]
  var tree: SyntaxTree?
  var needsParse = true
  /// 構文木が誤りを含む（色の問い合わせに枠を掛ける）。
  var crumbled = false
  /// 並びから外した。
  var detached = false

  init(
    rules: GrammarRules, depth: Int, parent: SyntaxLayer?, isCombined: Bool,
    parts: [InjectionPart]
  ) {
    self.rules = rules
    self.depth = depth
    self.parent = parent
    self.isCombined = isCombined
    self.parts = parts
  }

  /// 層の座標で、マッチの終わりの最も遠いところ。
  var extent: Int { parts.map(\.match.upperBound).max() ?? 0 }

  /// 解析器に含める範囲（昇順で重ならない。束ねた層は重なりを繋ぐ）。根は空＝全体。
  var includedRanges: [TSRange] {
    guard isCombined else {
      return parts.first?.ranges.filter { $0.end_byte > $0.start_byte } ?? []
    }
    var result: [TSRange] = []
    for range in parts.flatMap(\.ranges).sorted(by: { $0.start_byte < $1.start_byte })
    where range.end_byte > range.start_byte {
      if let last = result.last, range.start_byte <= last.end_byte {
        if range.end_byte > last.end_byte {
          result[result.count - 1].end_byte = range.end_byte
          result[result.count - 1].end_point = range.end_point
        }
      } else {
        result.append(range)
      }
    }
    return result
  }

  /// 層の座標の編集を、木と範囲へ写す。
  func edit(_ edit: TSInputEdit) {
    tree?.edit(edit)
    for index in parts.indices {
      parts[index].edit(edit)
    }
    needsParse = true
  }

  func descends(from ids: Set<ObjectIdentifier>) -> Bool {
    var layer: SyntaxLayer? = self
    while let current = layer {
      if ids.contains(ObjectIdentifier(current)) { return true }
      layer = current.parent
    }
    return false
  }
}

/// 注入のマッチ 1 つぶんの、マッチの範囲（UTF-16）と注入の範囲（バイトと行・桁）。どちらも層の座標。
struct InjectionPart {
  var match: Range<Int>
  var ranges: [TSRange]

  /// tree-sitter が木の含める範囲へ写すのと同じ規則で、編集を写す。
  mutating func edit(_ edit: TSInputEdit) {
    let start = Int(edit.start_byte) / 2
    let oldEnd = Int(edit.old_end_byte) / 2
    let newEnd = Int(edit.new_end_byte) / 2
    func moved(_ offset: Int) -> Int {
      offset >= oldEnd ? newEnd + offset - oldEnd : (offset > start ? start : offset)
    }
    match = moved(match.lowerBound)..<max(moved(match.lowerBound), moved(match.upperBound))
    for index in ranges.indices { ranges[index].edit(edit) }
  }

  static func same(_ lhs: [InjectionPart], _ rhs: [InjectionPart]) -> Bool {
    lhs.count == rhs.count
      && zip(lhs, rhs).allSatisfy { lhs, rhs in
        lhs.match == rhs.match && lhs.ranges.count == rhs.ranges.count
          && zip(lhs.ranges, rhs.ranges).allSatisfy {
            $0.start_byte == $1.start_byte && $0.end_byte == $1.end_byte
          }
      }
  }
}

/// 層と、その原点（本文の上の UTF-16 と行）。束ねない層の原点は、マッチの始まり以前の行頭（作ったときはマッチの始まりの
/// 行頭）——行頭に置くのは、層の木の桁を本文の桁と揃えるため（字下げを読む文法がある）。
struct Placed {
  let layer: SyntaxLayer
  let origin: Int
  let row: Int

  init(layer: SyntaxLayer, origin: Int, row: Int) {
    self.layer = layer
    self.origin = origin
    self.row = row
  }

  /// 束ねない層のマッチの範囲（本文の上）。
  var globalMatch: Range<Int> {
    let match = layer.parts[0].match
    return (origin + match.lowerBound)..<(origin + match.upperBound)
  }

  /// 区画を層の座標のバイトへ。層が区画より後ろなら nil。
  func bytes(of piece: Range<Int>) -> Range<Int>? {
    let lower = max(piece.lowerBound, origin) - origin
    let upper = piece.upperBound - origin
    return upper > lower ? (lower * 2)..<(upper * 2) : nil
  }

  /// 注入の範囲（本文の上）と区画の積（昇順）。
  func clip(to piece: Range<Int>) -> [Range<Int>] {
    layer.includedRanges.compactMap { range in
      let lower = max(piece.lowerBound, origin + Int(range.start_byte) / 2)
      let upper = min(piece.upperBound, origin + Int(range.end_byte) / 2)
      return lower < upper ? lower..<upper : nil
    }
  }

  /// 層の木の節の字。
  func text(of node: TSNode, in text: TextRope) -> String {
    let start = Int(ts_node_start_byte(node)) / 2
    let end = Int(ts_node_end_byte(node)) / 2
    return text.substring(NSRange(location: origin + start, length: end - start))
  }
}

/// 問い直して見つかった注入 1 つ（生んだ層の座標）。
struct Injection {
  let rules: GrammarRules
  let parent: Placed
  let combined: Bool
  let matchStart: Int
  let matchStartPoint: TSPoint
  let matchEnd: Int
  let ranges: [TSRange]

  /// マッチの範囲（本文の上）。
  var globalMatch: Range<Int> {
    (parent.origin + matchStart / 2)..<(parent.origin + matchEnd / 2)
  }

  /// 束ねない層として置いたもの。原点はマッチの始まりの行頭。
  func placed() -> Placed {
    let originByte = matchStart - Int(matchStartPoint.column)
    let originRow = matchStartPoint.row
    let ranges = ranges.map { range in
      TSRange(
        start_point: TSPoint(
          row: range.start_point.row - originRow, column: range.start_point.column),
        end_point: TSPoint(row: range.end_point.row - originRow, column: range.end_point.column),
        start_byte: range.start_byte - UInt32(originByte),
        end_byte: range.end_byte - UInt32(originByte))
    }
    let part = InjectionPart(
      match: ((matchStart - originByte) / 2)..<((matchEnd - originByte) / 2), ranges: ranges)
    let layer = SyntaxLayer(
      rules: rules, depth: parent.layer.depth + 1, parent: parent.layer, isCombined: false,
      parts: [part])
    return Placed(
      layer: layer, origin: parent.origin + originByte / 2, row: parent.row + Int(originRow))
  }

  /// 束ねる層の部分（本文の座標）。
  var combinedPart: InjectionPart {
    let byte = UInt32(parent.origin * 2)
    let row = UInt32(parent.row)
    let ranges = ranges.map { range in
      TSRange(
        start_point: TSPoint(row: range.start_point.row + row, column: range.start_point.column),
        end_point: TSPoint(row: range.end_point.row + row, column: range.end_point.column),
        start_byte: range.start_byte + byte, end_byte: range.end_byte + byte)
    }
    return InjectionPart(match: globalMatch, ranges: ranges)
  }
}

extension Injection {
  /// 内容の節の範囲（`includesChildren` でなければ名前付きの子の節を除く）を、生んだ層の含める範囲との積で切ったもの
  /// （生んだ層の座標。`parentRanges` が nil なら全体）。除くのが名前付きの子だけなのは、同梱の queries がその意味で
  /// 書かれているから——Markdown の段落の続きの `>` は名前付きの子（除く）、段落の中の記号は名前の無い子（除くと inline の
  /// 文法が区切りを見失う）。
  static func contentRanges(
    _ nodes: [TSNode], includesChildren: Bool, within parentRanges: [TSRange]?
  ) -> [TSRange] {
    let pieces = nodes.flatMap { includesChildren ? [range(of: $0)] : excludingNamedChildren($0) }
    guard let parentRanges else { return pieces }
    return pieces.flatMap { piece in
      parentRanges.compactMap { range -> TSRange? in
        guard range.start_byte < piece.end_byte, range.end_byte > piece.start_byte else {
          return nil
        }
        var clipped = piece
        if range.start_byte > clipped.start_byte {
          (clipped.start_byte, clipped.start_point) = (range.start_byte, range.start_point)
        }
        if range.end_byte < clipped.end_byte {
          (clipped.end_byte, clipped.end_point) = (range.end_byte, range.end_point)
        }
        return clipped
      }
    }
  }

  private static func range(of node: TSNode) -> TSRange {
    TSRange(
      start_point: ts_node_start_point(node), end_point: ts_node_end_point(node),
      start_byte: ts_node_start_byte(node), end_byte: ts_node_end_byte(node))
  }

  /// 節の範囲から名前付きの子の節を除いた、空でない区間の列。
  private static func excludingNamedChildren(_ node: TSNode) -> [TSRange] {
    var result: [TSRange] = []
    var start = (byte: ts_node_start_byte(node), point: ts_node_start_point(node))
    func append(until byte: UInt32, _ point: TSPoint) {
      guard byte > start.byte else { return }
      result.append(
        TSRange(start_point: start.point, end_point: point, start_byte: start.byte, end_byte: byte))
    }
    var walker = ts_tree_cursor_new(node)
    defer { ts_tree_cursor_delete(&walker) }
    if ts_tree_cursor_goto_first_child(&walker) {
      repeat {
        let child = ts_tree_cursor_current_node(&walker)
        guard ts_node_is_named(child) else { continue }
        append(until: ts_node_start_byte(child), ts_node_start_point(child))
        if ts_node_end_byte(child) > start.byte {
          start = (ts_node_end_byte(child), ts_node_end_point(child))
        }
      } while ts_tree_cursor_goto_next_sibling(&walker)
    }
    append(until: ts_node_end_byte(node), ts_node_end_point(node))
    return result
  }
}

/// 外した子の層を戻すときの照合の鍵——言語と注入の範囲（本文の上）。原点は照合に使わない——戻す層の原点は、編集で
/// マッチの始まりの行頭からずれていても、行頭でマッチより前にあり、木と範囲がその原点で揃っている。
struct RestoreKey: Hashable {
  let grammar: Grammar
  let ranges: [Int]

  init(_ placed: Placed) {
    grammar = placed.layer.rules.grammar
    ranges = placed.layer.parts[0].ranges.flatMap {
      [placed.origin * 2 + Int($0.start_byte), placed.origin * 2 + Int($0.end_byte)]
    }
  }
}

extension Range<Int> {
  /// マッチの範囲が区画に掛かるか（空のマッチは区画の中にあれば掛かる）。注入の存否を決める区画は、この規則で選ぶ——
  /// tree-sitter はパターンの根の節が区間と交わるマッチを返すが、捕まえた節が区画の外にあるマッチは、その節の区画で決める。
  func touches(_ piece: Range<Int>) -> Bool {
    overlaps(piece) || piece.contains(lowerBound)
  }
}

extension TSInputEdit {
  /// 本文の編集を、原点 `origin`（行 `row` の行頭）の層の座標へ。
  init(_ record: VersionedEdit, origin: Int, row: Int) {
    let edit = record.edit
    self.init(
      start_byte: UInt32((edit.range.location - origin) * 2),
      old_end_byte: UInt32((NSMaxRange(edit.range) - origin) * 2),
      new_end_byte: UInt32((NSMaxRange(edit.newRange) - origin) * 2),
      start_point: TSPoint(record.start, row: row), old_end_point: TSPoint(record.oldEnd, row: row),
      new_end_point: TSPoint(record.newEnd, row: row))
  }
}

extension TSPoint {
  /// 本文の行と桁（UTF-16）を、行 `row` を原点とする層の座標（桁はバイト）へ。
  fileprivate init(_ point: TextPoint, row: Int) {
    self.init(row: UInt32(point.row - row), column: UInt32(point.column * 2))
  }

  /// tree-sitter の `point_sub`。
  fileprivate static func difference(_ lhs: TSPoint, _ rhs: TSPoint) -> TSPoint {
    lhs.row > rhs.row
      ? TSPoint(row: lhs.row - rhs.row, column: lhs.column)
      : TSPoint(row: 0, column: lhs.column - rhs.column)
  }

  /// tree-sitter の `point_add`。
  fileprivate static func sum(_ lhs: TSPoint, _ rhs: TSPoint) -> TSPoint {
    rhs.row > 0
      ? TSPoint(row: lhs.row + rhs.row, column: rhs.column)
      : TSPoint(row: lhs.row, column: lhs.column + rhs.column)
  }
}

extension TSRange {
  /// tree-sitter が木の含める範囲に編集を写すのと同じ規則。
  fileprivate mutating func edit(_ edit: TSInputEdit) {
    func moved(_ byte: UInt32, _ point: TSPoint) -> (UInt32, TSPoint) {
      if byte >= edit.old_end_byte {
        return (
          edit.new_end_byte + (byte - edit.old_end_byte),
          .sum(edit.new_end_point, .difference(point, edit.old_end_point))
        )
      }
      return byte > edit.start_byte ? (edit.start_byte, edit.start_point) : (byte, point)
    }
    (end_byte, end_point) = moved(end_byte, end_point)
    (start_byte, start_point) = moved(start_byte, start_point)
  }
}
