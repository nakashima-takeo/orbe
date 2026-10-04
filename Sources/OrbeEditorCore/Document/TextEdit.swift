import Foundation

/// テキスト面で起きた 1 回の置換。`range` は変更前の本文での区間、`replacement` は置換後の中身の UTF-16 の単位で、
/// `replacementLength` はその長さ（tree-sitter の既定符号化と一致する）。中身を Swift の文字列でなく単位で運ぶのは、
/// 面の本文がサロゲートの対の片割れを持ちうるから（対を割る置換とその undo）——文字列にすると片割れが U+FFFD に化け、
/// 写しが面の本文からずれる。
public struct TextEdit: Equatable, Sendable {
  public let range: NSRange
  public let replacement: ContiguousArray<UInt16>
  public var replacementLength: Int { replacement.count }

  public init(range: NSRange, replacement: ContiguousArray<UInt16>) {
    self.range = range
    self.replacement = replacement
  }

  public init(range: NSRange, replacement: String) {
    self.init(range: range, replacement: ContiguousArray(replacement.utf16))
  }

  /// 置換後の本文での、置き換わった区間。
  public var newRange: NSRange { NSRange(location: range.location, length: replacementLength) }

  /// 編集の前の区間の列（昇順）を編集の後の本文へ写す——編集より前はそのまま、後ろは平行移動し、編集に掛かる区間は
  /// 落とす（取り直すまでの間、地が字からずれて見えないようにする）。
  public func track(_ ranges: [NSRange]) -> [NSRange] {
    EditSweep([self]).track(ranges)
  }

  /// 置換の前後で変わらない先頭と末尾を落とした編集——本文が実際に変わった最小の区間。`old` は置き換える前の区間の
  /// 単位。サロゲートの対は割らない。
  public func narrowed(replacing old: ContiguousArray<UInt16>) -> TextEdit {
    guard !old.isEmpty, replacementLength > 0 else { return self }
    let new = replacement
    let limit = min(old.count, new.count)
    var prefix = 0
    while prefix < limit, old[prefix] == new[prefix] { prefix += 1 }
    if prefix > 0, UTF16.isLeadSurrogate(old[prefix - 1]) { prefix -= 1 }
    var suffix = 0
    while suffix < limit - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
      suffix += 1
    }
    if suffix > 0, UTF16.isTrailSurrogate(old[old.count - suffix]) { suffix -= 1 }
    guard prefix > 0 || suffix > 0 else { return self }
    return TextEdit(
      range: NSRange(location: range.location + prefix, length: old.count - prefix - suffix),
      replacement: ContiguousArray(new[prefix..<(new.count - suffix)]))
  }

  /// 編集の前の区間の集合を編集の後の本文へ写す。`track` と違い落とさない——編集に掛かる（接する）なら、置換後の区間を
  /// 足す（「まだ作り直していない」「変わった」の集合を、編集に合わせて広げる）。
  public func track(_ set: IndexSet) -> IndexSet {
    EditSweep([self]).track(set)
  }

  /// 本文の長さの変化。
  public var change: Int { replacementLength - range.length }
}

/// 位置の掃引——束（重ならない昇順の編集の列。どれも束の前の本文の座標）で、位置・区間の列を 1 回の走査でずらす。ずらし方の
/// 定義はここだけにあり、どの結果も束の編集を後ろから 1 つずつ当てたのと同じ。手間は編集の数と位置の数の和に比例する
/// （カーソルが多い編集で、編集の数 × 位置の数にならない）。
public struct EditSweep: Sendable {
  public let edits: [TextEdit]

  /// `edits` は重ならない昇順（同じ位置の挿入と置換は挿入が先）。
  public init(_ edits: [TextEdit]) {
    self.edits = edits
  }

  /// 当てた順の編集の列（どれもその直前の本文の座標）を、続けて当てたのと同じになる束の列に分ける——次の編集が前の編集より
  /// 前で終わる並び（後ろから当てた並び）を 1 つの束にまとめる。文書は束を後ろから当てるので、束の数だけの掃引で済む。
  public static func batches(applied edits: some Sequence<TextEdit>) -> [EditSweep] {
    var runs: [[TextEdit]] = []
    var run: [TextEdit] = []
    for edit in edits {
      if let previous = run.last,
        NSMaxRange(edit.range) > previous.range.location
          || (edit.range.length == 0 && previous.range.length == 0
            && edit.range.location == previous.range.location)
      {
        runs.append(run)
        run = []
      }
      run.append(edit)
    }
    if !run.isEmpty { runs.append(run) }
    return runs.map { EditSweep($0.reversed()) }
  }

  /// 位置を束の後へ写す。置き換わった区間の中は置換の終わり（中身の変わった置換の中で、書記素を割る位置に落とさない）。区間の
  /// 始まりは動かない（その位置の挿入の前に残る）。`offsets` の並びは問わない。
  public func map(_ offsets: [Int]) -> [Int] {
    var result = offsets
    var next = 0
    var delta = 0
    for index in offsets.indices.sorted(by: { offsets[$0] < offsets[$1] }) {
      let offset = offsets[index]
      while next < edits.count, NSMaxRange(edits[next].range) <= offset {
        delta += edits[next].change
        next += 1
      }
      if next < edits.count, edits[next].range.location < offset {
        let edit = edits[next]
        result[index] =
          edit.replacementLength > 0
          ? edit.range.location + delta + edit.replacementLength
          : edit.range.location + delta - insertionsAfter(edit.range.location, before: next)
      } else {
        result[index] = offset + delta - insertionsAfter(offset, before: next)
      }
    }
    return result
  }

  /// 区間の列（始まりの昇順）を束の後へ写す。区間ごとに、写した区間か、編集に掛かって落ちたなら nil——編集より前はそのまま、
  /// 後ろは平行移動し、編集に掛かる区間は落とす（空の区間は、その位置の挿入の前に残る）。
  public func trackEach(_ ranges: [NSRange]) -> [NSRange?] {
    var next = 0
    var delta = 0
    return ranges.map { item in
      while next < edits.count, NSMaxRange(edits[next].range) <= item.location {
        delta += edits[next].change
        next += 1
      }
      if next < edits.count, edits[next].range.location < NSMaxRange(item) { return nil }
      let shift = item.length == 0 ? delta - insertionsAfter(item.location, before: next) : delta
      return NSRange(location: item.location + shift, length: item.length)
    }
  }

  /// 位置 `point`（`next` より前の編集をすべて当てる位置）の前に残る挿入の増分——その位置の挿入と、その位置で終わる削除を
  /// 越えた先の位置の挿入。後ろから当てると、位置はそれらの削除で挿入の位置へ寄り、挿入はその位置の後ろに入る。
  private func insertionsAfter(_ point: Int, before next: Int) -> Int {
    var point = point
    var total = 0
    var k = next - 1
    while k >= 0 {
      let edit = edits[k]
      if edit.range.length == 0, edit.range.location == point {
        total += edit.change
      } else if edit.replacementLength == 0, NSMaxRange(edit.range) == point {
        point = edit.range.location
      } else {
        break
      }
      k -= 1
    }
    return total
  }

  /// 区間の列（始まりの昇順）を束の後へ写し、編集に掛かる区間は落とす。
  public func track(_ ranges: [NSRange]) -> [NSRange] {
    trackEach(ranges).compactMap { $0 }
  }

  /// 区間の集合を束の後へ写す——どの編集も、置き換えた区間を除き、後ろをずらし、編集に掛かる（接する）なら置換後の区間を
  /// 足す。編集が接していれば、後ろの編集で足した区間が前の編集の「接する」に効く（後ろから 1 つずつ当てたのと同じ）。
  public func track(_ set: IndexSet) -> IndexSet {
    guard !edits.isEmpty else { return set }
    var touches = [Bool](repeating: false, count: edits.count)
    var memberAtEnd = false
    for i in edits.indices.reversed() {
      let range = edits[i].range
      let end = NSMaxRange(range)
      if i + 1 < edits.count, end == edits[i + 1].range.location {
        memberAtEnd = edits[i + 1].replacementLength > 0 ? touches[i + 1] : memberAtEnd
      } else {
        memberAtEnd = set.contains(end)
      }
      touches[i] = memberAtEnd || set.intersects(integersIn: max(0, range.location - 1)..<end)
    }
    var result = IndexSet()
    var delta = 0
    var copied = 0
    func copy(upTo end: Int?) {
      let upper = end ?? Int.max
      guard copied < upper else { return }
      for piece in set.rangeView(of: copied..<upper) {
        result.insert(integersIn: (piece.lowerBound + delta)..<(piece.upperBound + delta))
      }
    }
    for (i, edit) in edits.enumerated() {
      copy(upTo: edit.range.location)
      let start = edit.range.location + delta
      if touches[i], edit.replacementLength > 0 {
        result.insert(integersIn: start..<(start + edit.replacementLength))
      }
      delta += edit.change
      copied = NSMaxRange(edit.range)
    }
    copy(upTo: nil)
    return result
  }
}
