import Foundation
import OrbeEditorCore

/// 変換の文節 1 つ——範囲（view が IME の文字列から作るときは文字列の先頭から、編集係が持つ間は文書の座標）と、IME が
/// 変換の対象として選んでいるか、IME が指定した下線と地の色（面の描く色空間に解いた値）。
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

/// 変換の終え方——確定（今の本文のまま終え、正味の変化を undo に載せる）と、取り消し（変換が無かったことにする。undo には
/// 触れない）。
enum CompositionEnd {
  case commit, cancel
}

/// 変換中の状態（面の編集係の中に高々 1 つ）。未確定の文字は文書に入っていて、ここは「どこが未確定か」と「変換の中の
/// 変化」を持つ。未確定の範囲は編集係が変換の呼び出しのたびに動かす——本文を変える道は編集係だけで、変換中は IME 以外の
/// 入口が先に変換を終えるので、範囲が本文とずれることは無い。
///
/// 変換は全カーソルに当たる（VS Code の composition）。IME とやりとりするのは主の未確定だけで、他のカーソルの未確定は、
/// IME の呼び出しを主に対する相対位置で写したもの。変換中はカーソルの列をまとめない（未確定の列と並びを揃えておく）。
struct Composition {
  /// カーソルごとの未確定の範囲（文書の座標。カーソルの列の順で、主が先頭）。当てる範囲が前のカーソルと重なって変換に
  /// 入らなかったカーソルは nil。主はいつも持つ。
  var marked: [NSRange?]
  /// 主の未確定の中の選択（IME の注目位置。文書の座標）。主のカーソルには載せない。
  var selection: NSRange
  /// 見た目（文節の範囲は未確定の先頭から）。どの未確定にも同じに写す。
  var appearance: MarkedAppearance
  /// 変換が始まる前のカーソルの列と本文（undo の要素の起点）。
  let cursorsBefore: CursorList
  let textBefore: TextRope
  /// 変換の中の変化を合成したもの（始まる前の本文の座標）。
  var changes: EditBatch
  /// 確定済みの文字を置き換えた（再変換・未確定の外を指した置き換えの範囲）。
  var replacesCommitted: Bool

  /// 主の未確定の範囲（IME に答える範囲）。
  var range: NSRange { marked.first.flatMap { $0 } ?? NSRange(location: 0, length: 0) }
}

/// 変換の規則（純関数）。IME の呼び出しの範囲を文書の座標に解き、変換の終わりの正味の変化と undo の種類を決める。
enum CompositionRules {
  /// 置き換える範囲。`replacement` は文書の座標で、指していなければ未確定（無ければ選択）。
  static func target(
    _ replacement: NSRange, marked: NSRange?, selection: NSRange, length: Int
  ) -> NSRange {
    self.replacement(replacement, length: length) ?? marked ?? selection
  }

  /// IME が指した置き換えの範囲。NSNotFound と、本文（未確定を含む）に収まらない範囲は指していないもの（nil）——
  /// NSTextView と同じく無視する。
  static func replacement(_ range: NSRange, length: Int) -> NSRange? {
    guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
      range.length <= length - range.location
    else { return nil }
    return range
  }

  /// 主の当て先 `target` を、各カーソルの基準の範囲 `bases`（主が先頭。未確定か選択）に同じ相対位置で当てた範囲（VS Code
  /// の `_compositionType`）——主の基準の範囲からの前後のずれを、各カーソルの基準の範囲に足す。主の他は、書記素の境へ外側に
  /// 寄せ（サロゲート対や結合文字を割らない）、基準の範囲がある行の中身（改行を除く）に収める（行頭に近いカーソルが前の行の
  /// 字や改行を消さない）。
  static func targets(_ target: NSRange, bases: [NSRange], in text: TextRope) -> [NSRange] {
    guard let primary = bases.first else { return [] }
    let before = target.location - primary.location
    let after = NSMaxRange(target) - NSMaxRange(primary)
    return bases.indices.map { index in
      guard index > 0 else { return target }
      let base = bases[index]
      let lower = text.lineStart(text.row(containing: base.location))
      let upper = max(
        NSMaxRange(base),
        NSMaxRange(text.contentRange(ofRow: text.row(containing: NSMaxRange(base))))
      )
      var start = min(max(base.location + before, lower), upper)
      if start < upper { start = max(lower, text.grapheme(containing: start).location) }
      var end = min(max(NSMaxRange(base) + after, start), upper)
      if end > start { end = min(upper, NSMaxRange(text.grapheme(containing: end - 1))) }
      return NSRange(location: start, length: end - start)
    }
  }

  /// 当てる範囲（主が先頭）のうち、束に入れるもの——主はいつも入れ、他は文書の順に、入れたものと重なれば（同じ位置に
  /// 始まるものを含む）外す。`candidates` が偽のカーソル（変換から外れたカーソル）は、重なりを見る前から入れない。
  static func accepted(_ targets: [NSRange], candidates: [Bool]? = nil) -> [Bool] {
    guard let primary = targets.first else { return [] }
    func conflicts(_ a: NSRange, _ b: NSRange) -> Bool {
      a.location == b.location || (a.location < NSMaxRange(b) && b.location < NSMaxRange(a))
    }
    var accepted = [Bool](repeating: false, count: targets.count)
    accepted[0] = true
    var last: NSRange?
    for index in targets.indices.sorted(by: { targets[$0].location < targets[$1].location }) {
      let range = targets[index]
      if index > 0 {
        guard candidates?[index] ?? true, !conflicts(range, primary),
          last.map({ !conflicts($0, range) }) ?? true
        else {
          continue
        }
        accepted[index] = true
      }
      last = range
    }
    return accepted
  }

  /// 未確定の中の選択を文書の座標にしたもの。`selected` は入れた文字列の先頭からの位置で、文字列の中に収める。
  static func innerSelection(_ selected: NSRange, at location: Int, length: Int) -> NSRange {
    let start = min(max(0, selected.location == NSNotFound ? length : selected.location), length)
    let end = min(start + max(0, selected.length), length)
    return NSRange(location: location + start, length: end - start)
  }

  /// IME が範囲を指して確定の文字を入れた後の選択（NSTextView と同じ）。置き換えが選択より前なら選択をずらし、後ろなら
  /// 保ち、重なれば入れた文字の終わりのキャレット。選択の終わりに接する置き換えは後ろ、キャレットから始まる置き換えは
  /// 重なる。
  static func selection(_ selection: NSRange, after edit: TextEdit) -> NSRange {
    self.selection(
      selection, after: edit, inserted: edit.newRange,
      shift: { $0 + (NSMaxRange(edit.range) <= $0 ? edit.change : 0) })
  }

  /// `selection(_:after:)` を、束の中の 1 つの置き換え `edit`（束の前の座標）について束の後の座標で出す。`inserted` は
  /// `edit` の置換後の区間（束の後の座標）、`shift` は束の後へ写す位置の写し（`EditBatch.shiftingPast`）。
  static func selection(
    _ selection: NSRange, after edit: TextEdit, inserted: NSRange, shift: (Int) -> Int
  ) -> NSRange {
    let range = edit.range
    let end = NSMaxRange(selection)
    if selection.location >= NSMaxRange(range) {
      let start = shift(selection.location)
      return NSRange(location: start, length: shift(end) - start)
    }
    if end < range.location || (selection.length > 0 && end == range.location) {
      let start = shift(selection.location)
      let own = NSMaxRange(range) <= end ? edit.change : 0
      return NSRange(location: start, length: shift(end) - own - start)
    }
    return NSRange(location: NSMaxRange(inserted), length: 0)
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

  /// 変換の終わりに記録する undo の種類。全カーソルの正味の変化が、確定済みの文字を置き換えない同じ文字列の変化（挿入と、
  /// 変換を始めた選択の置き換え）なら打鍵と同じ分類（NSTextView と同じく、選択の上の打鍵と同じまとまり）、確定済みの文字を
  /// 置き換えたなら前後で区切る。
  static func undoKind(_ net: EditBatch, replacesCommitted: Bool) -> UndoKind {
    guard !replacesCommitted, let first = net.edits.first,
      net.edits.allSatisfy({ $0.replacement == first.replacement })
    else { return .other }
    return first.replacement == ContiguousArray(" ".utf16) ? .typing(.firstSpace) : .typing(.other)
  }
}
