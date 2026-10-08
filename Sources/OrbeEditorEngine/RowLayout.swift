import Foundation
import OrbeEditorCore

/// 面の縦の並び——文書の行と、行の境ごとの差し込みの塊（文書に無い行の列か、区画）。行 ↔ y の式はここに
/// だけあり、描画・スクロールの範囲・面のスクロール操作・当たり・IME の矩形・ドラッグ・俯瞰がどれもこれを呼ぶ。
///
/// 文書の行 `r` の上端は `r × 行高 + （r より上の塊の高さの合計）`。塊は境の昇順に並び、高さの累積を持つので、行 ↔ y は
/// 塊の数の対数で引ける。差し込みが無ければどの式も `行 × 行高` と同じ浮動小数の計算になる（差し込みの無い面の位置と
/// 画素は変わらない）。
///
/// 値は main だけが作り変え（置く・面自身の編集でずらす・区画を測り直す）、描く材料と一緒に描画スレッドへ渡す。描画スレッド
/// は引き取った材料の版の並びで描く。
///
/// y を返す式は `scale` を取り、装置の画素（pt × 倍率）でも同じ式で引ける（描画スレッドは px で、main は pt で引く）。
struct RowLayout: Sendable {
  /// 塊の中身。区画は載せる側の区画の同一性で、区画そのものと絵は main だけが持つ（描く材料は材料の箱の `zones`）。
  enum Content: Sendable {
    case lines([String])
    case zone(ObjectIdentifier)
  }

  /// 縦の位置にあるもの——文書の行か、塊。
  enum Item: Equatable {
    case line(Int)
    case block(Int)
  }

  let lineHeight: Double
  /// 塊の境（文書の行 `boundaries[i]` の前——行 `boundaries[i]`−1 の後。昇順）・高さ（pt）・中身。
  private(set) var boundaries: [Int] = []
  private(set) var heights: [Double] = []
  private(set) var contents: [Content] = []
  /// 塊 `i` より前の塊の高さの合計（`prefix[i]`。要素は塊の数 + 1）。
  private var prefix: [Double] = [0]
  /// 区画を持つか。
  private(set) var hasZones = false
  /// 区画の同一性 → 塊の番号。
  private var zoneBlocks: [ObjectIdentifier: Int] = [:]
  /// 作り変えるたびに進む（並びから作るキャッシュの鍵）。
  private(set) var version = 0

  init(lineHeight: Double) {
    self.lineHeight = lineHeight
  }

  /// 塊 1 つ——境（文書の行 `line` の前）・高さ（pt）・中身。
  struct Block {
    var line: Int
    var height: Double
    var content: Content
  }

  /// 塊の列（境の昇順）で並びを置き直す。
  mutating func replace(_ blocks: [Block]) {
    boundaries = blocks.map(\.line)
    heights = blocks.map(\.height)
    contents = blocks.map(\.content)
    prefix = [0]
    prefix.reserveCapacity(blocks.count + 1)
    for height in heights { prefix.append(prefix[prefix.count - 1] + height) }
    zoneBlocks = [:]
    for (index, content) in contents.enumerated() {
      if case .zone(let id) = content { zoneBlocks[id] = index }
    }
    hasZones = !zoneBlocks.isEmpty
    version += 1
  }

  /// 塊の数。
  var count: Int { boundaries.count }

  var isEmpty: Bool { boundaries.isEmpty }

  // MARK: - 行 ↔ y

  /// 境が `line` 以下の塊の数（文書の行 `line` より上にある塊の数）。
  func blocks(above line: Int) -> Int {
    var low = 0
    var high = boundaries.count
    while low < high {
      let mid = (low + high) / 2
      if boundaries[mid] <= line { low = mid + 1 } else { high = mid }
    }
    return low
  }

  /// 文書の行 `line` の上端。
  func y(ofLine line: Int, scale: Double = 1) -> Double {
    Double(line) * (lineHeight * scale) + prefix[blocks(above: line)] * scale
  }

  /// 塊 `index` の上端。
  func top(ofBlock index: Int, scale: Double = 1) -> Double {
    Double(boundaries[index]) * (lineHeight * scale) + prefix[index] * scale
  }

  /// 文書の行 `line` の上端（表示の単位——行高を 1 とする縦の位置）。
  func unit(ofLine line: Int) -> Double {
    Double(line) + prefix[blocks(above: line)] / lineHeight
  }

  /// 塊 `index` の上端（表示の単位）。
  func unit(ofBlock index: Int) -> Double {
    Double(boundaries[index]) + prefix[index] / lineHeight
  }

  /// y にある項目。文書の行は範囲に収めない——先頭より上は負の行、最後の項目より下は行数以上の行。
  func item(atY y: Double, scale: Double = 1) -> Item {
    var low = 0
    var high = boundaries.count
    while low < high {
      let mid = (low + high) / 2
      if top(ofBlock: mid, scale: scale) <= y { low = mid + 1 } else { high = mid }
    }
    if low > 0, y < top(ofBlock: low - 1, scale: scale) + heights[low - 1] * scale {
      return .block(low - 1)
    }
    return .line(Int(((y - prefix[low] * scale) / (lineHeight * scale)).rounded(.down)))
  }

  /// y にある文書の行。塊の上なら次の文書の行（最終行の後の塊なら行数）。範囲に収めない。
  func line(atY y: Double, scale: Double = 1) -> Int {
    switch item(atY: y, scale: scale) {
    case .line(let line): line
    case .block(let index): boundaries[index]
    }
  }

  /// 縦の位置 `y` で先頭に見えている文書の行（塊の上なら次の文書の行。`lineCount` 行の文書の範囲に収める）。
  func firstVisibleLine(atY y: Double, lineCount: Int) -> Int {
    min(max(0, line(atY: y)), max(0, lineCount - 1))
  }

  /// y の範囲 `from...to` に掛かる文書の行（行数 `lineCount` の文書。無ければ nil）。
  func lines(from: Double, to: Double, lineCount: Int, scale: Double = 1) -> ClosedRange<Int>? {
    let first = max(0, line(atY: from, scale: scale))
    let last: Int
    switch item(atY: to, scale: scale) {
    case .line(let line): last = min(lineCount - 1, line)
    case .block(let index): last = min(lineCount - 1, boundaries[index] - 1)
    }
    return first <= last ? first...last : nil
  }

  /// y の範囲 `from..<to` に掛かる塊の番号。
  func blocks(from: Double, to: Double, scale: Double = 1) -> Range<Int> {
    var low = 0
    var high = boundaries.count
    while low < high {
      let mid = (low + high) / 2
      if top(ofBlock: mid, scale: scale) + heights[mid] * scale <= from {
        low = mid + 1
      } else {
        high = mid
      }
    }
    var end = low
    while end < boundaries.count, top(ofBlock: end, scale: scale) < to { end += 1 }
    return low..<end
  }

  // MARK: - 縦の端

  /// 最後の項目の上端——縦のスクロールの端。最終行の後に塊があれば、その下端から 1 行の高さ上（文書に無い行なら最後の行の
  /// 上端。区画なら、区画の下端の 1 行が画面の最上段に来る所で、行より高い区画の下側まで送れる）。
  func lastTop(lineCount: Int) -> Double {
    guard let index = trailingBlock(lineCount: lineCount) else {
      return y(ofLine: lineCount - 1)
    }
    return top(ofBlock: index) + max(0, heights[index] - lineHeight)
  }

  /// 最後の項目の上端（表示の単位。差し込みが無ければ最終行）。
  func lastUnit(lineCount: Int) -> Double {
    guard let index = trailingBlock(lineCount: lineCount) else {
      return unit(ofLine: lineCount - 1)
    }
    return unit(ofBlock: index) + max(0, heights[index] - lineHeight) / lineHeight
  }

  /// 最後の項目の上端 + 1（表示の単位。差し込みが無ければ行数）——スクロールバーと印の写像の入力。
  func contentLines(lineCount: Int) -> Double { lastUnit(lineCount: lineCount) + 1 }

  /// 全体の高さ（最後の項目の下端）。
  func totalHeight(lineCount: Int) -> Double {
    Double(lineCount) * lineHeight + prefix[prefix.count - 1]
  }

  /// 最終行の後の最後の塊（無ければ nil）。
  private func trailingBlock(lineCount: Int) -> Int? {
    guard let last = boundaries.last, last >= lineCount else { return nil }
    return boundaries.count - 1
  }

  // MARK: - 見えている範囲

  /// 縦の位置 `y`（端を越えていれば端に収めたもの）で先頭に見えている所（表示の単位）——文書の行の中なら隠れている割合を
  /// 0…1 に収める（`lineCount` 行の文書）。
  func firstUnit(atY position: Double, lineCount: Int) -> Double {
    switch item(atY: position) {
    case .line(let raw):
      let line = min(raw, max(0, lineCount - 1))
      return unit(ofLine: line) + min(max((position - y(ofLine: line)) / lineHeight, 0), 1)
    case .block(let index):
      return unit(ofBlock: index) + (position - top(ofBlock: index)) / lineHeight
    }
  }

  // MARK: - 面自身の編集

  /// 面自身の編集の束 `edits`（どれも編集前の本文 `before` の座標で、重ならない）の後の行へ境をずらす。境 r（r ≥ 1）は
  /// 「行 r−1 の後」で、行 r−1 の中身の終わり（改行の手前）に付く——付き先から始まる編集では動かず、付き先を消した編集
  /// では消した区間の始まりの行の後へ寄り、付き先より前の編集の行の増減だけずれる。境 0（文書の先頭）は動かない。
  mutating func shift(_ edits: [TextEdit], in before: TextRope) {
    guard !boundaries.isEmpty, !edits.isEmpty else { return }
    let changes = edits.map { edit in
      let start = edit.range.location
      let end = NSMaxRange(edit.range)
      let removed = before.row(containing: end) - before.row(containing: start)
      return (
        start: start, end: end,
        delta: edit.replacement.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } - removed
      )
    }.sorted { $0.start < $1.start }
    let total = changes.reduce(0) { $0 + $1.delta }
    let lastRow = before.row(containing: changes.map(\.end).max() ?? 0)
    // 境 r ≤ 最初の編集の行 は、付き先が編集より前にある。
    var index = blocks(above: before.row(containing: changes[0].start))
    guard index < boundaries.count else { return }
    while index < boundaries.count {
      let boundary = boundaries[index]
      if boundary - 1 > lastRow {
        boundaries[index] = boundary + total
      } else {
        let anchor = Self.anchor(of: boundary, in: before)
        var row = boundary - 1
        var delta = 0
        for change in changes {
          guard change.start < anchor else { break }
          if anchor < change.end {
            row = before.row(containing: change.start)
          } else {
            delta += change.delta
          }
        }
        boundaries[index] = row + delta + 1
      }
      index += 1
    }
    version += 1
  }

  /// 境 `boundary`（≥ 1）の付き先——行 boundary−1 の中身の終わり（改行の手前。CRLF なら CR の手前）。
  private static func anchor(of boundary: Int, in text: TextRope) -> Int {
    guard boundary < text.lineCount else { return text.length }
    let newline = text.lineStart(boundary) - 1
    guard newline > 0, text.units(in: NSRange(location: newline - 1, length: 1)).first == 0x0D
    else { return newline }
    return newline - 1
  }

  // MARK: - 区画

  /// 区画 `id` の塊の番号（無ければ nil）。
  func block(ofZone id: ObjectIdentifier) -> Int? { zoneBlocks[id] }
}
