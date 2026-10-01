import Foundation
import OrbeEditorCore

/// ミニマップの字 1 つ（シェーダの `MinimapCell` と同じ並び）。`packed` は桁（下位 16bit）・チャンクの中の行（次の 8bit）・
/// 字形の番号（上位 8bit）、`role` は色の番号（0 は素の文字色、1… は役割の番号の順）。
struct MinimapCellInstance {
  var packed: UInt32
  var role: UInt32
}

/// ミニマップの行を、チャンク（64 行）ごとに覚える（描画スレッドだけ）——行頭と描ける桁ぶんの行の頭（`TextRope.lineHeads`）
/// と、そこから Core の `MinimapLine.forEachCell` で作った「桁・行・字形・役割」の字の列。字の列は描くコマがその命令の列の
/// instance の buffer へ写し、字形の表と色の表を引くシェーダが描く——色を覚えないので外観が変わっても作り直さない。装飾の
/// 区間の行と x も同じ行の頭から引くので、描くたびにロープを読まない。チャンクは行の頭だけを読む（長い行が続いても読むのは
/// 描ける桁ぶん）——帯を遠くへドラッグしたコマで新しいチャンクがいくつ要っても、コマの予算に収まる。
///
/// 捨てるのは、変わった行（本文の編集と役割の変化を届いた順に当てる）が掛かるチャンクと、行の数が増減した編集ではその
/// 行より後ろのチャンク全部（64 行の区切りが全部ずれる）。覚える数は上限まで（最も長く使っていないものから捨てる）。幅・
/// 倍率・インデントの単位が変われば全部捨てる。
final class MinimapCells {
  static let lines = 64
  static let capacity = 64

  /// 覚える条件（変われば覚えたチャンクは使えない）。
  struct Key: Equatable {
    /// 字を描ける桁数（→ `MinimapLine.columns`）。
    var columns: Int
    /// 読む行の頭の長さ（UTF-16。字と装飾の x の両方に足りる長さ）。
    var heads: Int
    var tabSize: Int
  }

  /// チャンク 1 つ——行の頭と字の列。行の頭のオフセットは作った版のもの（前の行で字の数が変わる編集の後も中身と行頭どうしの
  /// 差は正しいので、使い手が今の本文のまとまりの頭へずらして読む）。
  struct Chunk {
    let heads: LineHeads
    let cells: [MinimapCellInstance]
  }

  private struct Entry {
    let chunk: Chunk
    var used: UInt64
  }

  private var entries: [Int: Entry] = [:]
  private var key = Key(columns: 0, heads: 0, tabSize: 4)
  private var clock: UInt64 = 0

  /// 覚えているチャンク（テストが捨て方を見る）。
  var cached: Set<Int> { Set(entries.keys) }

  /// 変わった行を受け取る（届いた順）。
  func receive(_ edits: [RowEdit]) {
    for edit in edits {
      let first = edit.rows.lowerBound / Self.lines
      if !edit.rolesOnly, edit.inserted != edit.rows.count {
        entries = entries.filter { $0.key < first }
      } else {
        let last = (max(edit.rows.lowerBound, edit.rows.upperBound - 1)) / Self.lines
        entries = entries.filter { $0.key < first || $0.key > last }
      }
    }
  }

  /// コマを始める。条件が変わっていれば全部捨てる。
  func beginFrame(_ key: Key) {
    guard key != self.key else { return }
    entries.removeAll()
    self.key = key
  }

  /// チャンク `index`（文書の行の中にあること。覚えていなければ作る）。
  func chunk(_ index: Int, text: TextRope, roles: RoleRuns) -> Chunk {
    clock += 1
    if let entry = entries[index] {
      entries[index]?.used = clock
      return entry.chunk
    }
    let rows = (index * Self.lines)..<min((index + 1) * Self.lines, text.lineCount)
    let heads = text.lineHeads(rows, limit: key.heads)
    let chunk = Chunk(heads: heads, cells: Self.cells(heads, roles: roles, key: key))
    if entries.count >= Self.capacity,
      let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key
    {
      entries[oldest] = nil
    }
    entries[index] = Entry(chunk: chunk, used: clock)
    return chunk
  }

  /// 先に作るチャンクの上限（1 コマの後に）。
  static let prefetchLimit = 6

  /// 描いた行 `lines` が前のコマから `motion` 行動いたとき、次のコマで要りそうなチャンク（同じ向きに 1〜2 倍動いた
  /// 先まで——出来事とコマの刻みがずれて 1 コマの動きは揺れる）のうち、覚えていないものを動く向きの近い方から先に作る
  /// （上限 `prefetchLimit`）。コマを出した後の仕事で、次のコマに間に合わなければそのコマがその場で作る——先に作った
  /// 列もその場で作る列も同じ本文の版から作り、本文や役割が変われば同じ規則で捨てるので、字が抜けたり古い字が出たり
  /// しない。
  func prefetch(_ lines: Range<Int>, motion: Int, text: TextRope, roles: RoleRuns) {
    let first = max(0, lines.lowerBound + min(motion, 2 * motion))
    let end = min(text.lineCount, lines.upperBound + max(motion, 2 * motion))
    guard first < end else { return }
    let indices = Array((first / Self.lines)...((end - 1) / Self.lines))
    for index in (motion > 0 ? indices : indices.reversed()).filter({ entries[$0] == nil })
      .prefix(Self.prefetchLimit)
    {
      _ = chunk(index, text: text, roles: roles)
    }
  }

  /// 色の番号（0 は素の文字色、1… は役割の番号の順）。
  static func colorIndex(_ role: SyntaxRole?) -> UInt32 {
    role.map { UInt32($0.rawValue + 1) } ?? 0
  }

  /// チャンクの行の頭 `heads` の字の列。役割は文書の役割の並びを引くだけ（役割がまだ揃っていない区間は素の文字色）。
  static func cells(_ heads: LineHeads, roles: RoleRuns, key: Key) -> [MinimapCellInstance] {
    let starts = heads.starts
    let count = starts.count - 1
    guard key.columns > 0 else { return [] }
    var cursor = roles.cursor(from: starts[0])
    var result: [MinimapCellInstance] = []
    result.reserveCapacity(heads.unitCount)
    let (tabSize, columns) = (key.tabSize, key.columns)
    var run = 0..<0
    var color: UInt32 = 0
    for row in 0..<count {
      var line = heads.head(row)
      if heads.isComplete(row) {
        if line.last == 0x0A { line = line.dropLast() }
        if line.last == 0x0D { line = line.dropLast() }
      }
      let lineStart = starts[row]
      let y = UInt32(row) << 16
      MinimapLine.forEachCell(line, tabSize: tabSize, columns: columns) { column, glyph, at in
        if !run.contains(lineStart + at) {
          let found = cursor.run(at: lineStart + at)
          run = found.range
          color = colorIndex(found.role)
        }
        result.append(
          MinimapCellInstance(packed: UInt32(column) | y | UInt32(glyph) << 24, role: color))
      }
    }
    return result
  }
}
