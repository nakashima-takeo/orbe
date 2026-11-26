import Foundation
import OrbeEditorCore

/// 面の縦の並び——文書の行と、行の境ごとの差し込みの塊（差し込んだ行の列か、絵の差し込みか、相手と同じ高さの空き）と、
/// 折り返す面の行ごとの折り返し（`LineWraps`）。行 ↔ y の式はここにだけあり、描画・スクロールの範囲・面のスクロール
/// 操作・当たり・IME の矩形・ドラッグ・俯瞰がどれもこれを呼ぶ。
///
/// 文書の行は 1 つ以上の段からなり（折り返さない行は 1 段）、段の高さは行高。文書の行 `r` の上端は
/// `（r より上の段の数）× 行高 + （r より上の塊の高さの合計）`。塊は境の昇順に並び、高さの累積を持つので、行 ↔ y は
/// 塊の数の対数（と折り返しの木の深さ）で引ける。差し込みも折り返しも無ければどの式も `行 × 行高` と同じ浮動小数の計算に
/// なる（差し込みの無い、折り返さない面の位置と画素は変わらない）。
///
/// 文書の行の区間の見え方（行の型と、2 列の面の左の列の「もう一方の番号」）も並びと一緒に持ち、差し込みの境と同じ規則で
/// 面自身の編集に追従させる。
///
/// 値は main だけが作り変え（置く・面自身の編集でずらす・絵の差し込みを測り直す・相手と同じ高さの空きを揃える）、描く
/// 材料と一緒に描画スレッドへ渡す。描画スレッドは引き取った材料の版の並びで描く。
///
/// y を返す式は `scale` を取り、装置の画素（pt × 倍率）でも同じ式で引ける（描画スレッドは px で、main は pt で引く）。
struct RowLayout: Sendable {
  /// 塊の中身（差し込んだ行の列か、絵の差し込みか、相手と同じ高さの空き）。絵の差し込みは載せる側の値の同一性で持ち、
  /// 絵の差し込みそのものと、それが返した絵（`ZonePicture`）は main だけが持つ（描く材料は材料の箱の `zones`）。
  enum Content: Sendable {
    case lines([InsertedLine])
    case zone(ObjectIdentifier)
    /// スクロールを共にする相手の面の絵の差し込み（同一性）と同じ高さの空き。
    case gap(ObjectIdentifier)
  }

  /// 縦の位置にあるもの——文書の行（とその中の段）か、塊。
  enum Item: Equatable {
    case line(Int, segment: Int)
    case block(Int)
  }

  let lineHeight: Double
  /// 塊の境（文書の行 `boundaries[i]` の前——行 `boundaries[i]`−1 の後。昇順）・高さ（pt）・中身。
  private(set) var boundaries: [Int] = []
  private(set) var heights: [Double] = []
  private(set) var contents: [Content] = []
  /// 塊 `i` より前の塊の高さの合計（`prefix[i]`。要素は塊の数 + 1）。
  private(set) var prefix: [Double] = [0]
  /// 絵の差し込みを持つか・相手と同じ高さの空きを持つか。
  private(set) var hasZones = false
  private(set) var hasGaps = false
  /// 行の右端の印を出せる行（区間か差し込んだ行）を持つか。
  private(set) var hasTrailingMarks = false
  /// 絵の差し込みの同一性 → 塊の番号。
  private var zoneBlocks: [ObjectIdentifier: Int] = [:]
  /// 文書の行の区間（始まりの行の昇順）。
  private(set) var spans: [LineSpan] = []
  /// 差し込んだ行が指す出どころの行の番号と、最後の区間より前の区間の行のもう一方の番号の、最も大きいもの（無ければ 0）。最後の区間は
  /// 行数で決まるので、問われたときに足す（→ `otherNumberMax`）。
  private var settledNumberMax = 0
  /// 行ごとの折り返し（折り返さない面は nil）。
  private(set) var wraps: LineWraps?
  /// 折り返しを待つ行（面自身の編集が掛かった行。編集の後の行の区間で、昇順。折り返していた行は 1 段の行に置き換えてある）
  /// と、区間ごとの前の折り返しの手がかり（行の数を変えない、行 1 つの編集だけ）と、置き換えで行ごとの折り返しの木を
  /// 変えたか。
  private(set) var unwrapped: [Range<Int>] = []
  private var resumes: [LineWrap.Resume?] = []
  private var unwrapChanged = false
  /// 作り変えるたびに進む（並びから作るキャッシュの鍵）。
  private(set) var version = 0

  init(lineHeight: Double) {
    self.lineHeight = lineHeight
  }

  /// 項目と段の境のわずかに上を境とみなす許容（行高に対する割合）。
  static let slack = 1e-9

  /// 塊 1 つ——境（文書の行 `line` の前）・高さ（pt）・中身。
  struct Block {
    var line: Int
    var height: Double
    var content: Content
  }

  /// 塊の列（境の昇順）と文書の行の区間（始まりの昇順）で並びを置き直す。
  mutating func replace(_ blocks: [Block], spans: [LineSpan]) {
    self.spans = spans
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
    hasGaps = contents.contains {
      if case .gap = $0 { return true }
      return false
    }
    hasTrailingMarks =
      spans.contains(where: \.allowsTrailingMark)
      || contents.contains {
        guard case .lines(let lines) = $0 else { return false }
        return lines.contains { $0.allowsTrailingMark && $0.line != nil }
      }
    settleNumbers()
    version += 1
  }

  /// 塊の数。
  var count: Int { boundaries.count }

  var isEmpty: Bool { boundaries.isEmpty }

  // MARK: - 行 ↔ y

  /// 境が `line` 以下の塊の数（文書の行 `line` より上にある塊の数）。
  func blocks(above line: Int) -> Int { Self.count(boundaries, atOrBelow: line) }

  /// 文書の行 `line` より上の段の数（折り返しが無ければ行の数）。
  func segments(before line: Int) -> Int { wraps?.segments(before: line) ?? line }

  /// 文書の行 `line` の段の数。
  func segments(ofLine line: Int) -> Int { wraps?.wrap(ofLine: line)?.segments ?? 1 }

  /// 文書の行 `line` の折り返し（1 段の行なら nil）。
  func wrap(ofLine line: Int) -> WrappedLine? { wraps?.wrap(ofLine: line) }

  /// 文書の行 `line` の上端。
  func y(ofLine line: Int, scale: Double = 1) -> Double {
    Double(segments(before: line)) * (lineHeight * scale) + prefix[blocks(above: line)] * scale
  }

  /// 文書の行 `line` の段 `segment` の上端。
  func y(ofSegment segment: Int, line: Int, scale: Double = 1) -> Double {
    y(ofLine: line, scale: scale) + Double(segment) * (lineHeight * scale)
  }

  /// 塊 `index` の上端。
  func top(ofBlock index: Int, scale: Double = 1) -> Double {
    Double(segments(before: boundaries[index])) * (lineHeight * scale) + prefix[index] * scale
  }

  /// 文書の行 `line` の上端（表示の単位——行高を 1 とする縦の位置）。
  func unit(ofLine line: Int) -> Double {
    Double(segments(before: line)) + prefix[blocks(above: line)] / lineHeight
  }

  /// 塊 `index` の上端（表示の単位）。
  func unit(ofBlock index: Int) -> Double {
    Double(segments(before: boundaries[index])) + prefix[index] / lineHeight
  }

  /// y にある項目。文書の行は範囲に収めない——先頭より上は負の行、最後の項目より下は行数以上の行（どちらも段 0）。項目と
  /// 段の上端のわずかに上は、その項目・段とみなす——上端に置いた y が、行と y の間の丸め（表示の単位との行き来・端数の
  /// 高さの累積）で上の項目に化けない。y から項目・行・位置を引く道はどれもここを通る。
  func item(atY y: Double, scale: Double = 1) -> Item {
    let y = y + lineHeight * scale * Self.slack
    var low = 0
    var high = boundaries.count
    while low < high {
      let mid = (low + high) / 2
      if top(ofBlock: mid, scale: scale) <= y { low = mid + 1 } else { high = mid }
    }
    if low > 0, y < top(ofBlock: low - 1, scale: scale) + heights[low - 1] * scale {
      return .block(low - 1)
    }
    let segment = Int(((y - prefix[low] * scale) / (lineHeight * scale)).rounded(.down))
    guard let wraps else { return .line(segment, segment: 0) }
    let found = wraps.line(atSegment: segment)
    return .line(found.line, segment: found.segment)
  }

  /// y にある文書の行。塊の上なら次の文書の行（最終行の後の塊なら行数）。範囲に収めない。
  func line(atY y: Double, scale: Double = 1) -> Int {
    switch item(atY: y, scale: scale) {
    case .line(let line, _): line
    case .block(let index): boundaries[index]
    }
  }

  /// y の範囲 `from...to` に掛かる文書の行（行数 `lineCount` の文書。無ければ nil）。
  func lines(from: Double, to: Double, lineCount: Int, scale: Double = 1) -> ClosedRange<Int>? {
    let first = max(0, line(atY: from, scale: scale))
    let last: Int
    switch item(atY: to, scale: scale) {
    case .line(let line, _): last = min(lineCount - 1, line)
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

  /// 最後の項目の上端——縦のスクロールの端。最終行の後に塊が無ければ最終行の最後の段の上端。塊があれば、その下端から 1 行の
  /// 高さ上（差し込んだ行なら最後の行の上端。絵の差し込みなら、その下端の 1 行が画面の最上段に来る所で、行より高い絵の
  /// 差し込みの下側まで送れる）。
  func lastTop(lineCount: Int) -> Double {
    guard let index = trailingBlock(lineCount: lineCount) else {
      return y(ofSegment: segments(ofLine: lineCount - 1) - 1, line: lineCount - 1)
    }
    return top(ofBlock: index) + max(0, heights[index] - lineHeight)
  }

  /// 最後の項目の上端（表示の単位。差し込みが無ければ最終行の最後の段）。
  func lastUnit(lineCount: Int) -> Double {
    guard let index = trailingBlock(lineCount: lineCount) else {
      return unit(ofLine: lineCount - 1) + Double(segments(ofLine: lineCount - 1) - 1)
    }
    return unit(ofBlock: index) + max(0, heights[index] - lineHeight) / lineHeight
  }

  /// 最後の項目の上端 + 1（表示の単位。差し込みが無ければ行数）——スクロールバーと印の写像の入力。
  func contentLines(lineCount: Int) -> Double { lastUnit(lineCount: lineCount) + 1 }

  /// 全体の高さ（最後の項目の下端）。
  func totalHeight(lineCount: Int) -> Double {
    Double(segments(before: lineCount)) * lineHeight + prefix[prefix.count - 1]
  }

  /// 最終行の後の最後の塊（無ければ nil）。
  private func trailingBlock(lineCount: Int) -> Int? {
    guard let last = boundaries.last, last >= lineCount else { return nil }
    return boundaries.count - 1
  }

  // MARK: - 面自身の編集

  /// 面自身の編集の束 `edits`（どれも編集前の本文 `before` の座標で、重ならない）の後の行へ、境と区間の始まりをずらす。境 r
  /// （r ≥ 1）は「行 r−1 の後」で、行 r−1 の中身の終わり（改行の手前）に付く——付き先から始まる編集では動かず、付き先を消した
  /// 編集では消した区間の始まりの行の後へ寄り、付き先より前の編集の行の増減だけずれる。境 0（文書の先頭）は動かない。区間の
  /// 始まり r も「行 r−1 の後」の境として同じに動く。値の変わった境か区間の始まりがあったときだけ版を進める——行の数を変えない
  /// 打鍵では何も動かないので、差し込みの多い並びでも列をなめず、書き換えもしない。
  ///
  /// 折り返す面では、編集が掛かる行の折り返しを 1 段の行に置き換え、その行（編集の後の行）を折り返しを待つ行に積む——束を
  /// 当てた後の本文で `rewrap` が計算し直す。
  mutating func shift(_ edits: [TextEdit], in before: TextRope) {
    guard !boundaries.isEmpty || !spans.isEmpty || wraps != nil, !edits.isEmpty else { return }
    let sorted = edits.sorted { $0.range.location < $1.range.location }
    // 編集の始まりと終わりの行を、本文を前から 1 度辿って引く（複数カーソルの打鍵で、編集ごとに木を引かない）。
    let ends = before.rows(
      ofAscending: sorted.flatMap { edit in
        [
          NSRange(location: edit.range.location, length: 0),
          NSRange(location: NSMaxRange(edit.range), length: 0),
        ]
      })
    let changes = sorted.enumerated().map { index, edit in
      let rows = ends[2 * index].lowerBound...ends[2 * index + 1].lowerBound
      return LineChange(
        start: edit.range.location, end: NSMaxRange(edit.range), rows: rows,
        delta: edit.replacement.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } - (rows.count - 1))
    }
    if wraps != nil { unwrap(changes, in: before) }
    guard !boundaries.isEmpty || !spans.isEmpty else { return }
    let shift = LineShift(changes: changes, before: before)
    var moved = shift.apply(to: &boundaries)
    if shift.apply(to: &spans) {
      settleNumbers()
      moved = true
    }
    if moved { version += 1 }
  }

  // MARK: - 絵の差し込み

  /// 絵の差し込み `id` の塊の番号（無ければ nil）。
  func block(ofZone id: ObjectIdentifier) -> Int? { zoneBlocks[id] }

  // MARK: - 文書の行の見え方

  /// 文書の行 `line` を含む区間の番号（最初の区間より上なら nil）。
  func span(containing line: Int) -> Int? {
    var low = 0
    var high = spans.count
    while low < high {
      let mid = (low + high) / 2
      if spans[mid].line <= line { low = mid + 1 } else { high = mid }
    }
    return low > 0 ? low - 1 : nil
  }

  /// 文書の行 `line` の行の型の番号。
  func style(ofLine line: Int) -> Int? { span(containing: line).flatMap { spans[$0].style } }

  /// 文書の行 `line` のもう一方の番号。
  func otherNumber(ofLine line: Int) -> Int? {
    guard let index = span(containing: line), let number = spans[index].otherNumber else {
      return nil
    }
    return number + line - spans[index].line
  }

  /// 2 列の面の左の列に描く番号の最も大きいもの（`lineCount` 行の文書。無ければ 0）。
  func otherNumberMax(lineCount: Int) -> Int {
    guard let last = spans.last, let number = last.otherNumber, lineCount > last.line else {
      return settledNumberMax
    }
    return max(settledNumberMax, number + lineCount - 1 - last.line)
  }

  /// 最後の区間を除く区間と差し込んだ行の番号の最大を出し直す。
  private mutating func settleNumbers() {
    var result = 0
    for content in contents {
      guard case .lines(let lines) = content else { continue }
      for line in lines { result = max(result, line.line.map { $0 + 1 } ?? 0) }
    }
    for (span, next) in zip(spans, spans.dropFirst()) {
      guard let number = span.otherNumber, next.line > span.line else { continue }
      result = max(result, number + next.line - 1 - span.line)
    }
    settledNumberMax = result
  }
}

/// 行ごとの折り返しを置く・面自身の編集に追従させる（→ `RowLayout.shift`）。
extension RowLayout {
  /// 行ごとの折り返しを置く（nil なら折り返さない）。
  mutating func setWraps(_ wraps: LineWraps?) {
    self.wraps = wraps
    unwrapped = []
    resumes = []
    unwrapChanged = false
    version += 1
  }

  /// 編集 `changes`（編集前の本文 `before` の座標。昇順）が掛かる行を 1 段の行に置き換え、折り返しを待つ行に積む。同じ行に
  /// 掛かる編集は 1 つにまとめる。1 段の行だけに掛かり行の数を変えない編集（打鍵の多く）は、木を変えない。
  mutating func unwrap(_ changes: [LineChange], in before: TextRope) {
    guard var wraps else { return }
    guard wraps.lineCount == before.lineCount else {
      // 本文と食い違う折り返しは捨てる（取引の確定で全部を計算し直す）。
      return setWraps(nil)
    }
    precondition(unwrapped.isEmpty, "折り返しを待つ行は、束を当てた後に計算し直してから次の束を受ける")
    var shifted = 0
    var after: [Range<Int>] = []
    var resumes: [LineWrap.Resume?] = []
    var edits: [(lines: Range<Int>, with: [WrappedLine?])] = []
    for group in LineGroup.of(changes) {
      let lines = group.rows.lowerBound..<(group.rows.upperBound + 1)
      let count = lines.count + group.delta
      after.append(lines.lowerBound + shifted..<lines.lowerBound + shifted + count)
      shifted += group.delta
      let old = lines.count == 1 && group.delta == 0 ? wraps.wrap(ofLine: lines.lowerBound) : nil
      resumes.append(
        old.map {
          LineWrap.Resume(old: $0, edited: group.start - before.lineStart(lines.lowerBound))
        }
      )
      let plain =
        wraps.segments(before: lines.upperBound) - wraps.segments(before: lines.lowerBound)
        == lines.count
      if group.delta != 0 || !plain {
        edits.append((lines, [WrappedLine?](repeating: nil, count: count)))
      }
    }
    wraps.replace(edits)
    self.wraps = wraps
    unwrapped = after
    self.resumes = resumes
    unwrapChanged = !edits.isEmpty
  }

  /// 折り返しを待つ行を `wrap`（連続する文書の行と、前の折り返しの手がかり → 行ごとの折り返し。1 段の行は nil）で計算し
  /// 直す。行ごとの折り返しの木が変わっていれば（段の数が同じでも、段の始まりが動いていれば）版を進める——描画スレッドへ
  /// 並びを渡し直す。
  mutating func rewrap(_ wrap: (Range<Int>, LineWrap.Resume?) -> [WrappedLine?]) {
    guard var wraps, !unwrapped.isEmpty else { return }
    var edits: [(lines: Range<Int>, with: [WrappedLine?])] = []
    for (range, resume) in zip(unwrapped, resumes) {
      let lines = wrap(range, resume)
      if lines.contains(where: { $0 != nil }) { edits.append((range, lines)) }
    }
    wraps.replace(edits)
    self.wraps = wraps
    if unwrapChanged || !edits.isEmpty { version += 1 }
    unwrapped = []
    resumes = []
    unwrapChanged = false
  }
}
