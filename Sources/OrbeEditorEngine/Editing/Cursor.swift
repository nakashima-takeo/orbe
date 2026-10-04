import CoreGraphics
import Foundation
import OrbeEditorCore

/// 選択の起点の単位（VS Code の `SelectionStartKind`）。伸ばすとき、動く端をこの単位に揃える。
enum SelectionUnit: Sendable {
  case character, word, line
}

/// カーソル 1 本。形は VS Code の `SingleCursorState` と同じ——選択は「起点の範囲」と「動く端」の和で、伸ばしても起点の
/// 範囲は動かない（ダブルクリックの語・行番号の列の行を保ったまま伸ばせる）。
struct Cursor: Equatable, Sendable {
  var selectionStart: NSRange
  var unit: SelectionUnit
  /// 動く端（キャレット）。
  var position: Int
  /// ↑↓で覚える横位置（pt、行頭から）。↑↓とページ送り以外で動けば忘れる。
  var desiredX: CGFloat?
  /// 動かない側の端の覚える横位置（VS Code の `selectionStartLeftoverVisibleColumns`）。⌥⌘↑↓で選択を上下の行へ写すときに
  /// 使う。伸ばす移動では保ち、畳む移動では動く端の横位置と同じになる。
  var anchorDesiredX: CGFloat?

  init(
    selectionStart: NSRange, unit: SelectionUnit, position: Int, desiredX: CGFloat? = nil,
    anchorDesiredX: CGFloat? = nil
  ) {
    self.selectionStart = selectionStart
    self.unit = unit
    self.position = position
    self.desiredX = desiredX
    self.anchorDesiredX = anchorDesiredX
  }

  /// その位置の、選択の無いカーソル。
  init(_ offset: Int, desiredX: CGFloat? = nil) {
    self.init(
      selectionStart: NSRange(location: offset, length: 0), unit: .character, position: offset,
      desiredX: desiredX, anchorDesiredX: desiredX)
  }

  /// `range` を選んだカーソル（単位は文字）。`reversed` なら動く端は先頭。
  static func selecting(_ range: NSRange, reversed: Bool = false) -> Cursor {
    let anchor = reversed ? NSMaxRange(range) : range.location
    let position = reversed ? range.location : NSMaxRange(range)
    return Cursor(
      selectionStart: NSRange(location: anchor, length: 0), unit: .character, position: position)
  }

  /// 動かない側の端（VS Code の `_computeSelection`）——動く端が起点の範囲の先頭より後ろ（または起点の範囲が空）なら
  /// 先頭、そうでなければ終わり。
  var anchor: Int {
    selectionStart.length == 0 || position > selectionStart.location
      ? selectionStart.location : NSMaxRange(selectionStart)
  }

  var selection: NSRange {
    let anchor = anchor
    return NSRange(location: min(anchor, position), length: abs(position - anchor))
  }

  /// 動く端が先頭にある（前へ伸ばした）選択か。
  var isReversed: Bool { position < anchor }

  /// 選択か起点の範囲がある（VS Code の `hasSelection`。伸ばさない ←→ はその端へ畳む）。
  var hasSelection: Bool { selection.length > 0 || selectionStart.length > 0 }

  /// 動く端を `offset` へ。`extending` なら起点の範囲と単位を保ち、そうでなければ全部をそこへ畳む。
  func moved(to offset: Int, extending: Bool, desiredX: CGFloat? = nil) -> Cursor {
    guard extending else { return Cursor(offset, desiredX: desiredX) }
    var cursor = self
    cursor.position = offset
    cursor.desiredX = desiredX
    return cursor
  }

  /// 本文の範囲 `0...length` に収めたもの。
  func clamped(to length: Int) -> Cursor {
    func clamp(_ x: Int) -> Int { min(max(0, x), length) }
    let start = clamp(selectionStart.location)
    return Cursor(
      selectionStart: NSRange(
        location: start, length: clamp(NSMaxRange(selectionStart)) - start),
      unit: unit, position: clamp(position), desiredX: desiredX, anchorDesiredX: anchorDesiredX)
  }

  /// 同じ選択か（動かない側の端と動く端が同じ。VS Code の `equalsSelection`）。
  func selects(like other: Cursor) -> Bool {
    anchor == other.anchor && position == other.position
  }
}

/// カーソルの列（VS Code の `CursorCollection`）。先頭が主のカーソル（契約の選択・候補窓・打鍵の見せ方・⌘F の起点が使う）、
/// 末尾が最後に足したカーソル（⌘D の探索の起点）。並びは足した順で、どの操作が列を作っても `limit` 本を越えない。
struct CursorList: Equatable, Sendable {
  /// カーソルの数の上限（VS Code の `multiCursorLimit` の既定）。
  static let limit = 10_000

  private(set) var primary: Cursor
  private(set) var others: [Cursor]

  /// 主と他のカーソル。上限を越える分は、主と先にあるものを残して後ろから切る。
  init(_ primary: Cursor, others: [Cursor] = []) {
    self.primary = primary
    self.others = others.count < Self.limit ? others : Array(others.prefix(Self.limit - 1))
  }

  /// 文書の順と関係なく、足した順の列（先頭が主）。
  init?(_ cursors: some Collection<Cursor>) {
    guard let first = cursors.first else { return nil }
    self.init(first, others: Array(cursors.dropFirst()))
  }

  var all: [Cursor] { [primary] + others }

  var count: Int { others.count + 1 }

  /// 最後に足したカーソル。
  var last: Cursor { others.last ?? primary }

  func map(_ transform: (Cursor) -> Cursor) -> CursorList {
    CursorList(transform(primary), others: others.map(transform))
  }

  /// 選択の列（主が先頭）。
  var selections: [NSRange] { all.map(\.selection) }

  /// 同じ選択の列か（数と、どのカーソルも動かない側の端と動く端が同じ）。
  func selects(like other: CursorList) -> Bool {
    count == other.count && primary.selects(like: other.primary)
      && zip(others, other.others).allSatisfy { $0.selects(like: $1) }
  }

  /// 重なった・接したカーソルを 1 本にする（VS Code の `normalize`）——どちらかが空なら接していれば、どちらも選択を持つなら
  /// 重なっていれば結合する。結合したものは列で先にある方（主が最優先）の場所に残る。選択が同じならその方をそのまま残し、
  /// 違えば和の選択にして、向きは負けた方が最後に足したカーソルならそちら（その場合、勝った方が最後に足したカーソルを
  /// 引き継ぐ）、そうでなければ勝った方に倣う。
  mutating func normalize() {
    guard !others.isEmpty else { return }
    let cursors = all
    var alive = [Bool](repeating: true, count: cursors.count)
    var lastAdded = cursors.count - 1
    let order = cursors.indices.sorted { a, b in
      let (x, y) = (cursors[a].selection, cursors[b].selection)
      return x.location != y.location ? x.location < y.location : NSMaxRange(x) < NSMaxRange(y)
    }
    var kept: [(index: Int, cursor: Cursor)] = []
    kept.reserveCapacity(cursors.count)
    for index in order {
      let next = (index: index, cursor: cursors[index])
      guard let current = kept.last else {
        kept.append(next)
        continue
      }
      let (a, b) = (current.cursor.selection, next.cursor.selection)
      let merges =
        a.length == 0 || b.length == 0
        ? b.location <= NSMaxRange(a) : b.location < NSMaxRange(a)
      guard merges else {
        kept.append(next)
        continue
      }
      let (winner, loser) = current.index < next.index ? (current, next) : (next, current)
      var merged = winner.cursor
      if !loser.cursor.selects(like: winner.cursor) {
        let reversed: Bool
        if loser.index == lastAdded {
          reversed = loser.cursor.isReversed
          lastAdded = winner.index
        } else {
          reversed = winner.cursor.isReversed
        }
        merged = Cursor.selecting(NSUnionRange(a, b), reversed: reversed)
      } else if loser.index == lastAdded {
        lastAdded = (0..<loser.index).last { alive[$0] } ?? 0
      }
      alive[loser.index] = false
      kept[kept.count - 1] = (winner.index, merged)
    }
    kept.sort { $0.index < $1.index }
    primary = kept[0].cursor
    others = kept.dropFirst().map(\.cursor)
  }
}

/// 面の編集の状態——コマンドの入力と出力。
struct EditState: Equatable, Sendable {
  var cursors: CursorList
  /// `setMark:` で置いた位置（面ごと。束の適用でずれる）。
  var mark: Int?
  /// 直前のコマンドがキル（⌃K など）だったか。続けたキルはキルバッファへ足す。
  var lastWasKill = false
  /// ⌘D・⌘⇧L の続き——探している問い（VS Code の `MultiCursorSession`）。⌘D・⌘⇧L の結果にだけ残り、それ以外のどの操作でも
  /// 消える。
  var continuation: SearchQuestion?

  init(
    cursors: CursorList, mark: Int? = nil, lastWasKill: Bool = false,
    continuation: SearchQuestion? = nil
  ) {
    self.cursors = cursors
    self.mark = mark
    self.lastWasKill = lastWasKill
    self.continuation = continuation
  }
}
