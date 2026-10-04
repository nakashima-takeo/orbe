import Foundation
import OrbeEditorCore

/// 編集の束——1 回の操作が本文に当てる置換の列。重ならない昇順で、どの範囲も束の前の本文の座標（VS Code の編集の適用と
/// 同じ）。コマンドが返し、面の編集係が 1 回の知らせで文書へ渡す単位で、undo の要素の中身でもある。
struct EditBatch: Equatable, Sendable {
  let edits: [TextEdit]

  static let empty = EditBatch([])

  init(_ edits: [TextEdit]) {
    self.edits = edits.sorted { $0.range.location < $1.range.location }
  }

  var isEmpty: Bool { edits.isEmpty }

  /// 各編集の置き換わった区間（束の後の本文の座標）。
  var newRanges: [NSRange] {
    var delta = 0
    return edits.map { edit in
      defer { delta += edit.replacementLength - edit.range.length }
      return NSRange(location: edit.range.location + delta, length: edit.replacementLength)
    }
  }

  /// 束の前の本文 `text` に当てた本文。
  func applied(to text: TextRope) -> TextRope {
    var result = text
    for edit in edits.reversed() { result.replace(edit.range, with: edit.replacement) }
    return result
  }

  /// 逆向きの束——束の後の本文に当てると、束の前の本文 `text` に戻る。
  func inverse(of text: TextRope) -> EditBatch {
    EditBatch(
      zip(edits, newRanges).map { edit, range in
        TextEdit(range: range, replacement: text.units(in: edit.range))
      })
  }

  /// 束の前の位置を束の後へ写す。置き換わった区間の中は置換の終わり。区間の始まりは動かない（→ `EditSweep.map`）。
  func map(_ offset: Int) -> Int {
    map([offset])[0]
  }

  /// 束の前の位置の列を束の後へ写す（並びは問わない。1 回の掃引）。
  func map(_ offsets: [Int]) -> [Int] {
    EditSweep(edits).map(offsets)
  }

  /// 位置を束の後へ写す写し——その位置以前で終わる置き換え（位置にある挿入を含む）の増減を足し、置き換えた区間の中なら
  /// 置換の終わり。NSTextView が範囲を指した置き換えの後に選択を写す向き（`map` は位置にある挿入の前に残す）。
  var shiftingPast: (Int) -> Int {
    let edits = edits
    let ends = edits.map { NSMaxRange($0.range) }
    let replaced = newRanges
    var sums = [0]
    sums.reserveCapacity(edits.count + 1)
    for edit in edits { sums.append(sums[sums.count - 1] + edit.change) }
    return { offset in
      var low = 0
      var high = ends.count
      while low < high {
        let mid = (low + high) / 2
        if ends[mid] <= offset { low = mid + 1 } else { high = mid }
      }
      if low < edits.count, edits[low].range.location < offset { return NSMaxRange(replaced[low]) }
      return offset + sums[low]
    }
  }

  /// この束の後に `next` を当てたのと同じ、1 つの束。`result` は両方を当てた後の本文。
  ///
  /// 2 つの束の変えた区間（この束の置換後の区間と `next` の範囲、どちらも中間の本文の座標）を、重なる・接するものごとに
  /// まとめ、まとめた区間ごとに「最初の本文での範囲 → 最後の本文での中身」の置換を 1 つ作る。打鍵のまとまりの undo を
  /// 1 つの束で知らせるため（束の数だけ配らない）。まとめた区間は昇順なので、区間の端の写しはどれも 1 回の掃引。
  func then(_ next: EditBatch, result: TextRope) -> EditBatch {
    guard !isEmpty else { return next }
    guard !next.isEmpty else { return self }
    let mine = newRanges
    let regions = Self.merge(mine, next.edits.map(\.range))
    var back = BackSweep(edits: edits, newRanges: mine)
    var through = ThroughSweep(edits: next.edits)
    var composed: [TextEdit] = []
    composed.reserveCapacity(regions.count)
    for region in regions {
      let start = back.start(region.location)
      let end = back.end(NSMaxRange(region))
      let resultStart = through.start(region.location)
      let resultEnd = through.end(NSMaxRange(region))
      composed.append(
        TextEdit(
          range: NSRange(location: start, length: end - start),
          replacement: result.units(
            in: NSRange(location: resultStart, length: resultEnd - resultStart))))
    }
    return EditBatch(composed)
  }

  /// 2 つの昇順の区間の列を合わせ、重なる・接する区間をまとめた昇順の列。
  private static func merge(_ a: [NSRange], _ b: [NSRange]) -> [NSRange] {
    var merged: [NSRange] = []
    merged.reserveCapacity(a.count + b.count)
    var i = 0
    var j = 0
    while i < a.count || j < b.count {
      let range: NSRange
      if j >= b.count || (i < a.count && a[i].location <= b[j].location) {
        range = a[i]
        i += 1
      } else {
        range = b[j]
        j += 1
      }
      if let last = merged.last, range.location <= NSMaxRange(last) {
        merged[merged.count - 1] = NSUnionRange(last, range)
      } else {
        merged.append(range)
      }
    }
    return merged
  }

  /// まとめた区間の端（束の後の本文の位置。昇順に問う）を束の前へ戻す。始まりが置換後の区間の始まりなら置換の範囲の始まり、
  /// 終わりが置換後の区間の終わりなら置換の範囲の終わり、それ以外は前にある編集の増減を戻す。
  private struct BackSweep {
    let edits: [TextEdit]
    let newRanges: [NSRange]
    private var startIndex = 0
    private var startDelta = 0
    private var endIndex = 0
    private var endDelta = 0

    init(edits: [TextEdit], newRanges: [NSRange]) {
      self.edits = edits
      self.newRanges = newRanges
    }

    mutating func start(_ offset: Int) -> Int {
      while startIndex < edits.count, newRanges[startIndex].location < offset {
        startDelta += edits[startIndex].replacementLength - edits[startIndex].range.length
        startIndex += 1
      }
      if startIndex < edits.count, newRanges[startIndex].location == offset {
        return edits[startIndex].range.location
      }
      return offset - startDelta
    }

    mutating func end(_ offset: Int) -> Int {
      while endIndex < edits.count, NSMaxRange(newRanges[endIndex]) <= offset {
        endDelta += edits[endIndex].replacementLength - edits[endIndex].range.length
        endIndex += 1
      }
      if endIndex > 0, NSMaxRange(newRanges[endIndex - 1]) == offset {
        return NSMaxRange(edits[endIndex - 1].range)
      }
      return offset - endDelta
    }
  }

  /// まとめた区間の端（`edits` の前の本文の位置。昇順に問う）を `edits` の後へ写す。始まりは区間に入る編集をまだ当てず、
  /// 終わりは区間に入る編集も当てる。
  private struct ThroughSweep {
    let edits: [TextEdit]
    private var startIndex = 0
    private var startDelta = 0
    private var endIndex = 0
    private var endDelta = 0

    init(edits: [TextEdit]) {
      self.edits = edits
    }

    mutating func start(_ offset: Int) -> Int {
      while startIndex < edits.count, NSMaxRange(edits[startIndex].range) < offset {
        startDelta += edits[startIndex].replacementLength - edits[startIndex].range.length
        startIndex += 1
      }
      return offset + startDelta
    }

    mutating func end(_ offset: Int) -> Int {
      while endIndex < edits.count, edits[endIndex].range.location <= offset {
        endDelta += edits[endIndex].replacementLength - edits[endIndex].range.length
        endIndex += 1
      }
      return offset + endDelta
    }
  }
}
