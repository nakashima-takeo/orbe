import CoreGraphics
import Foundation

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

  init(selectionStart: NSRange, unit: SelectionUnit, position: Int, desiredX: CGFloat? = nil) {
    self.selectionStart = selectionStart
    self.unit = unit
    self.position = position
    self.desiredX = desiredX
  }

  /// その位置の、選択の無いカーソル。
  init(_ offset: Int, desiredX: CGFloat? = nil) {
    self.init(
      selectionStart: NSRange(location: offset, length: 0), unit: .character, position: offset,
      desiredX: desiredX)
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
      unit: unit, position: clamp(position), desiredX: desiredX)
  }
}

/// カーソルの列——主のカーソル 1 本とその他（VS Code の `CursorCollection`）。操作が作るのは今は主の 1 本だけだが、
/// コマンド・undo・描画はこの列を前提に組む。
struct CursorList: Equatable, Sendable {
  var primary: Cursor
  var others: [Cursor] = []

  init(_ primary: Cursor, others: [Cursor] = []) {
    self.primary = primary
    self.others = others
  }

  var all: [Cursor] { [primary] + others }

  func map(_ transform: (Cursor) -> Cursor) -> CursorList {
    CursorList(transform(primary), others: others.map(transform))
  }

  /// 重なった・接したカーソルを 1 本にする（VS Code の `normalize`）——どちらかが空なら接していれば、どちらも選択を
  /// 持つなら重なっていれば結合する。結合したものの向きは、列で先にある方（主が最優先）に倣う。
  mutating func normalize() {
    guard !others.isEmpty else { return }
    var entries = all.enumerated().map { (index: $0.offset, cursor: $0.element) }
    entries.sort { a, b in
      let (x, y) = (a.cursor.selection, b.cursor.selection)
      return x.location != y.location ? x.location < y.location : NSMaxRange(x) < NSMaxRange(y)
    }
    var i = 0
    while i + 1 < entries.count {
      let (current, next) = (entries[i], entries[i + 1])
      let (a, b) = (current.cursor.selection, next.cursor.selection)
      let merges =
        a.length == 0 || b.length == 0
        ? b.location <= NSMaxRange(a) : b.location < NSMaxRange(a)
      guard merges else {
        i += 1
        continue
      }
      let winner = current.index < next.index ? current : next
      let union = NSUnionRange(a, b)
      entries[i] = (winner.index, Cursor.selecting(union, reversed: winner.cursor.isReversed))
      entries.remove(at: i + 1)
    }
    entries.sort { $0.index < $1.index }
    primary = entries[0].cursor
    others = entries.dropFirst().map(\.cursor)
  }
}

/// 面の編集の状態——コマンドの入力と出力。
struct EditState: Equatable, Sendable {
  var cursors: CursorList
  /// `setMark:` で置いた位置（面ごと。束の適用でずれる）。
  var mark: Int?
  /// 直前のコマンドがキル（⌃K など）だったか。続けたキルはキルバッファへ足す。
  var lastWasKill = false

  init(cursors: CursorList, mark: Int? = nil, lastWasKill: Bool = false) {
    self.cursors = cursors
    self.mark = mark
    self.lastWasKill = lastWasKill
  }
}
