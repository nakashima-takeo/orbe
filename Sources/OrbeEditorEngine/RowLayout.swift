import Foundation

/// 面の縦の並び——文書の行と、行の境ごとの差し込みの塊（文書に無い行の列か、view を載せる区画）。行 ↔ y の式はここに
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
  /// 塊の中身。区画は載せる側の view の識別で、view そのものは main だけが持つ。
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
  /// 塊の境（文書の行 `boundaries[i]` の前。昇順）・高さ（pt）・中身。
  private(set) var boundaries: [Int] = []
  private(set) var heights: [Double] = []
  private(set) var contents: [Content] = []
  /// 塊 `i` より前の塊の高さの合計（`prefix[i]`。要素は塊の数 + 1）。
  private var prefix: [Double] = [0]
  /// 区画を持つか。
  private(set) var hasZones = false
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
    hasZones = contents.contains {
      if case .zone = $0 { return true }
      return false
    }
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

  /// 最後の項目（最後の文書の行か、最終行の後の塊の最後の行・区画）の上端——縦のスクロールの端。
  func lastTop(lineCount: Int) -> Double {
    guard let index = trailingBlock(lineCount: lineCount) else {
      return y(ofLine: lineCount - 1)
    }
    return top(ofBlock: index) + Double(lastRow(ofBlock: index)) * lineHeight
  }

  /// 最後の項目の上端（表示の単位。差し込みが無ければ最終行）。
  func lastUnit(lineCount: Int) -> Double {
    guard let index = trailingBlock(lineCount: lineCount) else {
      return unit(ofLine: lineCount - 1)
    }
    return unit(ofBlock: index) + Double(lastRow(ofBlock: index))
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

  /// 塊の最後の項目の、塊の中の行（区画なら 0）。
  private func lastRow(ofBlock index: Int) -> Int {
    if case .lines(let lines) = contents[index] { return max(0, lines.count - 1) }
    return 0
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

  /// 編集 `edit` の後の行へ境をずらす——編集より前の境はそのまま、後ろの境は行の増減の分だけ、置き換えた区間の中の境は
  /// 区間の始まりの行へ。役割だけの変化は行を動かさない。
  mutating func shift(_ edit: RowEdit) {
    guard !boundaries.isEmpty, !edit.rolesOnly else { return }
    let first = edit.rows.lowerBound
    let end = edit.rows.upperBound
    let delta = edit.inserted - edit.rows.count
    var index = blocks(above: first)
    guard index < boundaries.count else { return }
    while index < boundaries.count {
      let boundary = boundaries[index]
      boundaries[index] = boundary >= end ? boundary + delta : first
      index += 1
    }
    version += 1
  }

  // MARK: - 区画

  /// 区画 `id` の塊の番号（無ければ nil）。
  func block(ofZone id: ObjectIdentifier) -> Int? {
    contents.firstIndex {
      if case .zone(let zone) = $0 { return zone == id }
      return false
    }
  }
}
