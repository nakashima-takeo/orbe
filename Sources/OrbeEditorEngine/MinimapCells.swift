import Foundation
import OrbeEditorCore

/// ミニマップの字 1 つ（シェーダの `MinimapCell` と同じ並び）。`packed` は桁（下位 16bit）・チャンクの中の行（次の 8bit）・
/// 字形の番号（上位 8bit）、`role` は色の番号（0 は素の文字色、1… は役割の番号の順）。
struct MinimapCellInstance {
  var packed: UInt32
  var role: UInt32
}

/// ミニマップの段（縮図の 1 段。折り返す面では本文の 1 段、折り返さない面では文書の行 1 つ）を、チャンク（64 段）ごとに
/// 覚える（描画スレッドだけ）——段の頭と描ける桁ぶんの段の先頭（`MinimapHeads`）と、そこから Core の
/// `MinimapLine.forEachCell` で作った「桁・段・字形・役割」の字の列。字の列は描くコマがその命令の列の instance の buffer へ
/// 写し、字形の表と色の表を引くシェーダが描く——色を覚えないので外観が変わっても作り直さない。装飾の区間の段と x も同じ段の
/// 先頭から引くので、描くたびにロープを読まない。チャンクは段の先頭だけを読む（長い行が続いても読むのは描ける桁ぶん）——帯を
/// 遠くへドラッグしたコマで新しいチャンクがいくつ要っても、コマの予算に収まる。
///
/// 捨てるのは、変わった行（本文の編集と役割の変化を届いた順に当てる）が掛かるチャンクと、段の位置がずれる編集の、その
/// 段より後ろのチャンク全部（64 段の区切りが全部ずれるため）。段の位置がずれるのは、行の数が変わる編集と、折り返す面で
/// 編集した行の段の数が変わったとき。覚える数は上限まで（最も長く使っていないものから捨てる）。幅・倍率・インデントの単位・
/// 折り返しの幅が変われば全部捨てる。
final class MinimapCells {
  static let lines = 64
  static let capacity = 64

  /// 覚える条件（変われば覚えたチャンクは使えない）。
  struct Key: Equatable {
    /// 字を描ける桁数（→ `MinimapLine.columns`）。
    var columns: Int
    /// 読む段の先頭の長さ（UTF-16。字と装飾の x の両方に足りる長さ）。
    var heads: Int
    var tabSize: Int
    /// 折り返しの幅（折り返さない面は nil）と、本文の 1 桁の幅（続きの段の字下げを桁にする）。
    var wrapWidth: Double?
    var cell: Double = 1
  }

  /// チャンク 1 つ——段の先頭と字の列。段の頭のオフセットは作った版のもの（前の段で字の数が変わる編集の後も中身と段の頭どうしの
  /// 差は正しいので、使い手が今の本文のまとまりの頭へずらして読む）。
  struct Chunk {
    let heads: MinimapHeads
    let cells: [MinimapCellInstance]
  }

  private struct Entry {
    let chunk: Chunk
    var used: UInt64
  }

  private var entries: [Int: Entry] = [:]
  private var key = Key(columns: 0, heads: 0, tabSize: 4)
  private var clock: UInt64 = 0
  /// 前に受け取った縦の並び（編集で段の位置がずれたかを見る）。
  private var seen: RowLayout?

  /// 覚えているチャンク（テストが捨て方を見る）。
  var cached: Set<Int> { Set(entries.keys) }

  /// 変わった行を受け取る（届いた順。`rows` は引き取った材料の縦の並び）。折り返す面では、編集した行の前後で段の位置が
  /// 前に受け取った並びと同じなら、編集した行の段が掛かるチャンクだけを捨てる。ずれていれば、どの編集より前の行の段は
  /// 変わらないので、それらの編集の最も上の行の段から後ろを捨てる。
  func receive(_ edits: [RowEdit], rows: RowLayout) {
    defer { seen = rows }
    guard rows.wraps != nil else { return receiveLines(edits) }
    guard !edits.isEmpty else { return }
    let structural = edits.contains { edit in
      guard !edit.rolesOnly else { return false }
      guard edit.inserted == edit.rows.count, let seen, seen.wraps != nil else { return true }
      return [edit.rows.lowerBound, edit.rows.upperBound].contains {
        seen.segments(before: $0) != rows.segments(before: $0)
      }
    }
    if structural {
      let first = edits.map(\.rows.lowerBound).min()!
      let chunk = rows.segments(before: first) / Self.lines
      entries = entries.filter { $0.key < chunk }
      return
    }
    for edit in edits {
      let first = rows.segments(before: edit.rows.lowerBound) / Self.lines
      let last = max(first, (rows.segments(before: edit.rows.upperBound) - 1) / Self.lines)
      entries = entries.filter { $0.key < first || $0.key > last }
    }
  }

  /// 折り返さない面の、変わった行の受け取り（段は文書の行）。
  private func receiveLines(_ edits: [RowEdit]) {
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

  /// ミニマップの段の数（`rows` は縦の並び。折り返さない面は文書の行の数）。
  static func count(text: TextRope, rows: RowLayout) -> Int {
    rows.wraps?.segmentCount ?? text.lineCount
  }

  /// チャンク `index`（ミニマップの段の中にあること。覚えていなければ作る）。
  func chunk(_ index: Int, text: TextRope, roles: RoleRuns, rows: RowLayout) -> Chunk {
    clock += 1
    if let entry = entries[index] {
      entries[index]?.used = clock
      return entry.chunk
    }
    let end = min((index + 1) * Self.lines, Self.count(text: text, rows: rows))
    let range = (index * Self.lines)..<end
    let heads = MinimapHeads(range, text: text, rows: rows, limit: key.heads, cell: key.cell)
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

  /// 描いた段 `lines` が前のコマから `motion` 段動いたとき、次のコマで要りそうなチャンク（同じ向きに 1〜2 倍動いた
  /// 先まで——出来事とコマの刻みがずれて 1 コマの動きは揺れる）のうち、覚えていないものを動く向きの近い方から先に作る
  /// （上限 `prefetchLimit`）。コマを出した後の仕事で、次のコマに間に合わなければそのコマがその場で作る——先に作った
  /// 列もその場で作る列も同じ本文の版から作り、本文や役割が変われば同じ規則で捨てるので、字が抜けたり古い字が出たり
  /// しない。
  func prefetch(
    _ lines: Range<Int>, motion: Int, text: TextRope, roles: RoleRuns, rows: RowLayout
  ) {
    let first = max(0, lines.lowerBound + min(motion, 2 * motion))
    let end = min(Self.count(text: text, rows: rows), lines.upperBound + max(motion, 2 * motion))
    guard first < end else { return }
    let indices = Array((first / Self.lines)...((end - 1) / Self.lines))
    for index in (motion > 0 ? indices : indices.reversed()).filter({ entries[$0] == nil })
      .prefix(Self.prefetchLimit)
    {
      _ = chunk(index, text: text, roles: roles, rows: rows)
    }
  }

  /// 色の番号（0 は素の文字色、1… は役割の番号の順）。
  static func colorIndex(_ role: SyntaxRole?) -> UInt32 {
    role.map { UInt32($0.rawValue + 1) } ?? 0
  }

  /// チャンクの段の先頭 `heads` の字の列。役割は文書の役割の並びを引くだけ（役割がまだ揃っていない区間は素の文字色）。続きの
  /// 段は字下げの桁から描く。
  static func cells(_ heads: MinimapHeads, roles: RoleRuns, key: Key) -> [MinimapCellInstance] {
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
      let indent = heads.indents[row]
      let fitting = columns - indent
      MinimapLine.forEachCell(line, tabSize: tabSize, columns: fitting) { local, glyph, at in
        let column = local + indent
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

/// ミニマップの段の先頭（`MinimapCells`）——段の頭のオフセット（段の数 + 1 個。最後は最後の段の終わり）と、それぞれの段の
/// 先頭 `limit` 単位（行の最後の段は行末の改行を含みうる）と、続きの段の字下げの桁。
struct MinimapHeads {
  let starts: [Int]
  let units: ContiguousArray<UInt16>
  let bounds: [Int]
  let ends: [Int]
  let indents: [Int]

  /// ミニマップの段 `range`（`rows` の縦の並びで。折り返さない面は文書の行）の先頭を読む。`cell` は本文の 1 桁の幅。
  init(_ range: Range<Int>, text: TextRope, rows: RowLayout, limit: Int, cell: Double) {
    guard let wraps = rows.wraps else {
      let heads = text.lineHeads(range, limit: limit)
      starts = heads.starts
      var units = ContiguousArray<UInt16>()
      units.reserveCapacity(heads.unitCount)
      var bounds = [0]
      for index in 0..<range.count {
        units.append(contentsOf: heads.head(index))
        bounds.append(units.count)
      }
      self.units = units
      self.bounds = bounds
      ends = Array(heads.starts.dropFirst())
      indents = [Int](repeating: 0, count: range.count)
      return
    }
    var starts: [Int] = []
    var units = ContiguousArray<UInt16>()
    var bounds = [0]
    var ends: [Int] = []
    var indents: [Int] = []
    var line = -1
    var lineStart = 0
    var lineEnd = 0
    for index in range {
      let found = wraps.line(atSegment: index)
      if found.line != line {
        line = found.line
        lineStart = text.lineStart(line)
        lineEnd = line + 1 < text.lineCount ? text.lineStart(line + 1) : text.length
      }
      let wrap = rows.wrap(ofLine: line)
      let start = lineStart + (wrap?.start(of: found.segment) ?? 0)
      var end = lineEnd
      if let wrap, found.segment + 1 < wrap.segments {
        end = lineStart + wrap.start(of: found.segment + 1)
      }
      starts.append(start)
      ends.append(end)
      units.append(
        contentsOf: text.units(in: NSRange(location: start, length: min(end - start, limit))))
      bounds.append(units.count)
      indents.append(
        found.segment > 0 ? Int((Double(wrap?.indent ?? 0) / max(cell, 1)).rounded()) : 0)
    }
    starts.append(ends.last ?? text.length)
    self.starts = starts
    self.units = units
    self.bounds = bounds
    self.ends = ends
    self.indents = indents
  }

  /// 読んだ単位の数。
  var unitCount: Int { units.count }

  /// `index` 番目の段の先頭。
  func head(_ index: Int) -> ArraySlice<UInt16> { units[bounds[index]..<bounds[index + 1]] }

  /// `index` 番目の段の先頭が段の終わり（行の最後の段なら、改行を含む行の終わり）まで届いているか。
  func isComplete(_ index: Int) -> Bool {
    bounds[index + 1] - bounds[index] == ends[index] - starts[index]
  }
}
