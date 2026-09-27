import Metal
import OrbeEditorCore

/// ミニマップの字 1 つ（シェーダの `MinimapCell` と同じ並び）。`packed` は桁（下位 16bit）・チャンクの中の行（次の 8bit）・
/// 字形の番号（上位 8bit）、`role` は色の番号（0 は素の文字色、1… は `SyntaxRole.allCases` の順）。
struct MinimapCellInstance {
  var packed: UInt32
  var role: UInt32
}

/// ミニマップの字を、チャンク（64 行）ごとに「桁・行・字形・役割」の列として覚える（描画スレッドだけ）。列は Core の
/// `MinimapLine.cells` から作って GPU の buffer に置き、描くのは字形の表と色の表を引くシェーダ——色を覚えないので外観が
/// 変わっても作り直さず、帯を遠くへドラッグしたコマでも新しいチャンク 1 つは数十 µs で済む。
///
/// 捨てるのは、変わった行の列（本文の編集と役割の変化を届いた順に当てる）が掛かるチャンクと、行の数が増減した編集ではその
/// 行より後ろのチャンク全部（64 行の区切りが全部ずれる）。覚える数は上限まで（最も長く使っていないものから捨てる）。幅・
/// 倍率・インデントの単位が変われば全部捨てる。作り直すときは新しい buffer に書く（GPU が読んでいる buffer は命令の列が
/// 手放すまで生きる）。
final class MinimapCells {
  static let lines = 64
  static let capacity = 64

  /// 列を作る条件（変われば覚えた列は使えない）。
  struct Key: Equatable {
    /// 描ける桁数（→ `MinimapLine.columns`）。
    var columns: Int
    var tabSize: Int
  }

  private struct Entry {
    let buffer: MTLBuffer?
    let count: Int
    var used: UInt64
  }

  private let device: MTLDevice
  private var entries: [Int: Entry] = [:]
  private var key: Key?
  private var clock: UInt64 = 0

  init(device: MTLDevice) {
    self.device = device
  }

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

  /// 面が閉じた・結び直した。
  func reset() {
    entries.removeAll()
    key = nil
  }

  /// チャンク `index` の列（覚えていなければ作る）。字が無ければ buffer は nil。
  func chunk(_ index: Int, text: TextRope, roles: RoleRuns) -> (
    buffer: MTLBuffer?, count: Int
  ) {
    clock += 1
    if let entry = entries[index] {
      entries[index]?.used = clock
      return (entry.buffer, entry.count)
    }
    let cells = Self.cells(index, text: text, roles: roles, key: key ?? Key(columns: 0, tabSize: 4))
    let buffer =
      cells.isEmpty
      ? nil
      : cells.withUnsafeBytes {
        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
      }
    if entries.count >= Self.capacity,
      let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key
    {
      entries[oldest] = nil
    }
    entries[index] = Entry(buffer: buffer, count: cells.count, used: clock)
    return (buffer, cells.count)
  }

  /// 色の番号（0 は素の文字色）。
  static let roleIndex: [SyntaxRole: UInt32] = Dictionary(
    uniqueKeysWithValues: SyntaxRole.allCases.enumerated().map { ($1, UInt32($0 + 1)) })

  /// チャンクの字の列。役割は文書の役割の並びを引くだけ（役割がまだ揃っていない区間は素の文字色）。
  static func cells(_ index: Int, text: TextRope, roles: RoleRuns, key: Key)
    -> [MinimapCellInstance]
  {
    let firstRow = index * lines
    guard firstRow < text.lineCount, key.columns > 0 else { return [] }
    let rows = firstRow..<min(firstRow + lines, text.lineCount)
    let start = text.lineStart(rows.lowerBound)
    let range = NSRange(location: start, length: text.lineEnd(rows.upperBound - 1) - start)
    let units = text.units(in: range)
    let spans = roles.roles(in: range)
    var result: [MinimapCellInstance] = []
    var span = 0
    for row in rows {
      let lineStart = text.lineStart(row)
      let from = lineStart - start
      var end = text.lineEnd(row) - start
      if end > from, units[end - 1] == 0x0A { end -= 1 }
      if end > from, units[end - 1] == 0x0D { end -= 1 }
      while span < spans.count, NSMaxRange(spans[span].range) <= lineStart { span += 1 }
      let cells = MinimapLine.cells(
        units[from..<end], lineStart: lineStart, roles: spans[span...], tabSize: key.tabSize,
        columns: key.columns)
      let y = UInt32(row - rows.lowerBound) << 16
      for cell in cells {
        result.append(
          MinimapCellInstance(
            packed: UInt32(cell.column) | y | UInt32(cell.glyph) << 24,
            role: cell.role.flatMap { Self.roleIndex[$0] } ?? 0))
      }
    }
    return result
  }
}
