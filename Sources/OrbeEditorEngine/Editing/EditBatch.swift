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

  /// 束の前の位置を束の後へ写す。置き換わった区間の中は、置換の中の同じ距離（収まらなければ置換の終わり）。
  func map(_ offset: Int) -> Int {
    var delta = 0
    for edit in edits {
      if offset <= edit.range.location { break }
      if offset >= NSMaxRange(edit.range) {
        delta += edit.replacementLength - edit.range.length
        continue
      }
      return edit.range.location + delta + min(offset - edit.range.location, edit.replacementLength)
    }
    return offset + delta
  }

  /// この束の後に `next` を当てたのと同じ、1 つの束。`result` は両方を当てた後の本文。
  ///
  /// 2 つの束の変えた区間（この束の置換後の区間と `next` の範囲、どちらも中間の本文の座標）を、重なる・接するものごとに
  /// まとめ、まとめた区間ごとに「最初の本文での範囲 → 最後の本文での中身」の置換を 1 つ作る。打鍵のまとまりの undo を
  /// 1 つの束で知らせるため（束の数だけ配らない）。
  func then(_ next: EditBatch, result: TextRope) -> EditBatch {
    guard !isEmpty else { return next }
    guard !next.isEmpty else { return self }
    let regions = Self.merge(newRanges + next.edits.map(\.range))
    var composed: [TextEdit] = []
    for region in regions {
      let start = mapBack(start: region.location)
      let end = mapBack(end: NSMaxRange(region))
      let resultStart = next.mapThrough(start: region.location)
      let resultEnd = next.mapThrough(end: NSMaxRange(region))
      composed.append(
        TextEdit(
          range: NSRange(location: start, length: end - start),
          replacement: result.units(
            in: NSRange(location: resultStart, length: resultEnd - resultStart))))
    }
    return EditBatch(composed)
  }

  /// 重なる・接する区間をまとめた昇順の列。
  private static func merge(_ ranges: [NSRange]) -> [NSRange] {
    var merged: [NSRange] = []
    for range in ranges.sorted(by: { $0.location < $1.location }) {
      if let last = merged.last, range.location <= NSMaxRange(last) {
        merged[merged.count - 1] = NSUnionRange(last, range)
      } else {
        merged.append(range)
      }
    }
    return merged
  }

  /// 束の後の本文の位置のうち、まとめた区間の始まりを束の前へ戻す（置換後の区間の始まりなら置換の範囲の始まり）。
  private func mapBack(start offset: Int) -> Int {
    var delta = 0
    for (edit, range) in zip(edits, newRanges) {
      if range.location == offset { return edit.range.location }
      if range.location > offset { break }
      delta += edit.replacementLength - edit.range.length
    }
    return offset - delta
  }

  /// 束の後の本文の位置のうち、まとめた区間の終わりを束の前へ戻す（置換後の区間の終わりなら置換の範囲の終わり）。
  private func mapBack(end offset: Int) -> Int {
    var delta = 0
    var found: Int?
    for (edit, range) in zip(edits, newRanges) {
      if range.location > offset { break }
      if NSMaxRange(range) == offset { found = NSMaxRange(edit.range) }
      if NSMaxRange(range) <= offset { delta += edit.replacementLength - edit.range.length }
    }
    return found ?? offset - delta
  }

  /// 束の前の本文の位置のうち、まとめた区間の始まりを束の後へ写す（区間に入る編集はまだ当てない）。
  private func mapThrough(start offset: Int) -> Int {
    var delta = 0
    for edit in edits where NSMaxRange(edit.range) < offset {
      delta += edit.replacementLength - edit.range.length
    }
    return offset + delta
  }

  /// 束の前の本文の位置のうち、まとめた区間の終わりを束の後へ写す（区間に入る編集も当てる）。
  private func mapThrough(end offset: Int) -> Int {
    var delta = 0
    for edit in edits where edit.range.location <= offset {
      delta += edit.replacementLength - edit.range.length
    }
    return offset + delta
  }
}
