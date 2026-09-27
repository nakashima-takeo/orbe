import Foundation
import OrbeEditorCore

/// 変換の文節 1 つ——範囲（view が IME の文字列から作るときは文字列の先頭から、編集係が持つ間は文書の座標）と、IME が
/// 変換の対象として選んでいるか、IME が指定した下線と地の色（sRGB）。
struct MarkedClause: Equatable, Sendable {
  var range: NSRange
  var active: Bool
  var underline: UInt32?
  var background: UInt32?
}

/// 変換の見た目——文節の列と、属性の無い文字列（地で塗る）か。
struct MarkedAppearance: Equatable, Sendable {
  var clauses: [MarkedClause] = []
  var filled = false
}

extension MarkedAppearance {
  /// 文節の範囲を `offset` だけずらしたもの（入れた文字列の先頭から → 文書の座標）。
  func shifted(by offset: Int) -> MarkedAppearance {
    var shifted = self
    shifted.clauses = clauses.map {
      var clause = $0
      clause.range.location += offset
      return clause
    }
    return shifted
  }
}

/// 変換の終え方——確定（今の本文のまま終え、正味の変化を undo に載せる）と、取り消し（変換が無かったことにする。undo には
/// 触れない）。
enum CompositionEnd {
  case commit, cancel
}

/// 変換中の状態（面の編集係の中に高々 1 つ）。未確定の文字は文書に入っていて、ここは「どこが未確定か」と「変換の中の
/// 変化」を持つ。未確定の範囲は編集係が変換の呼び出しのたびに動かす——本文を変える道は編集係だけで、変換中は IME 以外の
/// 入口が先に変換を終えるので、範囲が本文とずれることは無い。
struct Composition {
  /// 未確定の範囲（文書の座標）。
  var range: NSRange
  /// 未確定の中の選択（IME の注目位置。文書の座標）。主のカーソルには載せない。
  var selection: NSRange
  var appearance: MarkedAppearance
  /// 変換が始まる前のカーソルの列と本文（undo の要素の起点）。
  let cursorsBefore: CursorList
  let textBefore: TextRope
  /// 変換の中の変化を合成したもの（始まる前の本文の座標）。
  var changes: EditBatch
  /// 確定済みの文字を置き換えた（再変換・未確定の外を指した置き換えの範囲）。
  var replacesCommitted: Bool
}

/// 変換の規則（純関数）。IME の呼び出しの範囲を文書の座標に解き、変換の終わりの正味の変化と undo の種類を決める。
enum CompositionRules {
  /// 置き換える範囲。`replacement` は文書の座標で、NSNotFound なら未確定（無ければ選択）。本文の外へはみ出す分は切る。
  static func target(
    _ replacement: NSRange, marked: NSRange?, selection: NSRange, length: Int
  ) -> NSRange {
    guard replacement.location != NSNotFound else { return marked ?? selection }
    let start = min(max(0, replacement.location), length)
    let end = min(max(start, replacement.location + max(0, replacement.length)), length)
    return NSRange(location: start, length: end - start)
  }

  /// 未確定の中の選択を文書の座標にしたもの。`selected` は入れた文字列の先頭からの位置で、文字列の中に収める。
  static func innerSelection(_ selected: NSRange, at location: Int, length: Int) -> NSRange {
    let start = min(max(0, selected.location == NSNotFound ? length : selected.location), length)
    let end = min(start + max(0, selected.length), length)
    return NSRange(location: location + start, length: end - start)
  }

  /// 置き換えの範囲が確定済みの文字に掛かるか（未確定の範囲そのものか、始まる前の選択なら掛からない）。
  static func replacesCommitted(_ target: NSRange, marked: NSRange?, selection: NSRange) -> Bool {
    if let marked { return target != marked }
    return target != selection
  }

  /// 変換の中の変化から、変わらない先頭と末尾を落とした正味の変化（本文が元のままなら空）。
  static func net(_ changes: EditBatch, before: TextRope) -> EditBatch {
    EditBatch(
      changes.edits.compactMap { whole in
        let old = before.units(in: whole.range)
        guard old != whole.replacement else { return nil }
        return whole.narrowed(replacing: old)
      })
  }

  /// 変換の終わりに記録する undo の種類。確定済みの文字を置き換えない変化 1 つ（挿入と、変換を始めた選択の置き換え）は
  /// 打鍵と同じ分類（NSTextView と同じく、選択の上の打鍵と同じまとまり）、確定済みの文字を置き換えたなら前後で区切る。
  static func undoKind(_ net: EditBatch, replacesCommitted: Bool) -> UndoKind {
    guard !replacesCommitted, net.edits.count == 1, let edit = net.edits.first else {
      return .other
    }
    return edit.replacement == ContiguousArray(" ".utf16) ? .typing(.firstSpace) : .typing(.other)
  }
}
