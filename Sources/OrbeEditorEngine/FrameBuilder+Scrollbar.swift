import Foundation
import OrbeEditorCore

/// 検索の一致と語の出現を行へ写した結果を覚える（描画スレッドだけ）。本文の編集では、覚えた区間と行を同じ編集でずらし、
/// 届いた区間の列がずらした列と同じなら行もずらしたものを使い回す（打鍵のたびに EditorSearch が一致をずらして押し直しても、
/// 1MB・19999 件を写し直さない）。写し直すのは区間の列が本当に変わったとき（検索語を変えた）だけ。
final class RulerRows {
  private struct Mapped {
    var ranges: [NSRange] = []
    var rows: [ClosedRange<Int>] = []
    /// 置き直された列の回数（`Highlights` の版）。
    var revision = -1
    /// 行を写し直した・ずらした回数（印の図形を作り直すかの判断）。
    var generation = 0
  }

  private var find = Mapped()
  private var word = Mapped()
  /// このコマで写し直した区間の数（計測）。
  private(set) var remappedInFrame = 0

  /// 本文の編集を受け取り、覚えた区間と行をずらす。
  func receive(_ edits: [RowEdit]) {
    for edit in edits where !edit.rolesOnly {
      Self.shift(&find, by: edit)
      Self.shift(&word, by: edit)
    }
  }

  /// 検索の一致の行と、その世代。
  func find(_ highlights: Highlights, text: TextRope) -> (rows: [ClosedRange<Int>], generation: Int)
  {
    remappedInFrame = 0
    update(&find, highlights.find, revision: highlights.findRevision, text: text)
    return (find.rows, find.generation)
  }

  /// 語の出現の行と、その世代。
  func word(_ highlights: Highlights, text: TextRope) -> (rows: [ClosedRange<Int>], generation: Int)
  {
    update(&word, highlights.word, revision: highlights.wordRevision, text: text)
    return (word.rows, word.generation)
  }

  private func update(_ mapped: inout Mapped, _ ranges: [NSRange], revision: Int, text: TextRope) {
    guard revision != mapped.revision else { return }
    mapped.revision = revision
    guard ranges != mapped.ranges else { return }
    mapped.ranges = ranges
    mapped.rows = text.rows(ofAscending: ranges)
    mapped.generation += 1
    remappedInFrame += ranges.count
  }

  /// 編集の後の本文へずらす——編集より前はそのまま、後ろは平行移動（行は増減した行の数だけ）、編集に掛かる区間は落とす
  /// （`TextEdit.track` と同じ規則）。全部の行が変わった編集では覚えたものを捨てる。
  private static func shift(_ mapped: inout Mapped, by edit: RowEdit) {
    guard !mapped.ranges.isEmpty else { return }
    guard let change = edit.text else {
      mapped = Mapped(revision: -1, generation: mapped.generation + 1)
      return
    }
    let range = change.range
    let delta = change.replacementLength - range.length
    let rowDelta = edit.inserted - edit.rows.count
    var ranges: [NSRange] = []
    var rows: [ClosedRange<Int>] = []
    ranges.reserveCapacity(mapped.ranges.count)
    rows.reserveCapacity(mapped.rows.count)
    for (item, row) in zip(mapped.ranges, mapped.rows) {
      if NSMaxRange(item) <= range.location {
        ranges.append(item)
        rows.append(row)
      } else if item.location >= NSMaxRange(range) {
        ranges.append(NSRange(location: item.location + delta, length: item.length))
        rows.append((row.lowerBound + rowDelta)...(row.upperBound + rowDelta))
      }
    }
    mapped.ranges = ranges
    mapped.rows = rows
    mapped.generation += 1
  }
}

/// 印の図形の元（行・行数・高さ・倍率）が変わったときだけ、印の縦の区間を作り直して覚える。
struct RulerSpans {
  struct Key: Equatable {
    var find: Int
    var word: Int
    var marks: RowMarks
    var lineCount: Int
    var visibleLines: CGFloat
    var height: CGFloat
    var scale: CGFloat
    var current: NSRange?
  }

  var key: Key?
  /// 色ごとの縦の区間（描く順）。
  var groups: [(kind: Kind, spans: [OverviewRuler.Span])] = []

  /// 印の種類（色とレーン）。
  enum Kind {
    case added, modified, removed, word, find

    /// git は左、検索の一致と語の出現は中央。
    var lane: OverviewRuler.Lane {
      switch self {
      case .added, .modified, .removed: .left
      case .word, .find: .center
      }
    }
  }
}

/// 縦横のスクロールバーと印・影。どれもこのコマの本文の位置（端を越えている間は端）から出す。
extension FrameBuilder {
  /// 上端の影（先頭の行が隠れている間。行番号の列から本文の区画の右端まで）と、ミニマップの左の影（本文が右に続く
  /// とき。本文の区画の上、影の帯の外側）。濃さは CSS のぼかし（σ 3 のガウスの縁）を 9 点で写した勾配で、画素の中心で
  /// 引く。
  func drawShadows(
    _ layout: SurfaceLayout, lines: (first: CGFloat, visible: CGFloat), clipsRight: Bool,
    _ c: Context
  ) {
    let g = c.g
    let depth = 6.0
    if lines.first > 0 {
      let rows = Int((depth * g.scale).rounded())
      for y in 0..<rows {
        let strength = Self.shadowStrength((Double(y) + 0.5) / g.scale, length: depth)
        shadowShapes.append(
          ShapeInstance(
            rect: SIMD4(0, Float(y), Float(g.textRight), 1),
            color: c.palette.overview.topShadow.scaled(alpha: strength), radius: 0, kind: 0))
      }
    }
    guard clipsRight else { return }
    let band = (Double(layout.minimap.minX) - depth) * g.scale
    let columns = Int((2 * depth * g.scale).rounded())
    for step in 0..<columns {
      let x = band.rounded() - Double(step + 1)
      guard x >= 0 else { break }
      let strength = Self.shadowStrength((band - (x + 0.5)) / g.scale, length: 2 * depth)
      shadowShapes.append(
        ShapeInstance(
          rect: SIMD4(Float(x), 0, 1, Float(g.height)),
          color: c.palette.overview.minimapShadow.scaled(alpha: strength), radius: 0, kind: 0))
    }
  }

  /// 影の縁から `distance` pt の濃さ——`0.5·erfc(d / (σ√2))`（σ 3）を長さ `length` に 9 点で置いた折れ線。
  static func shadowStrength(_ distance: Double, length: Double) -> Double {
    let t = min(max(distance / length, 0), 1) * 8
    let k = min(Int(t), 7)
    let a = 0.5 * erfc(Double(k) / 8 * length / (3 * 2.0.squareRoot()))
    let b = 0.5 * erfc(Double(k + 1) / 8 * length / (3 * 2.0.squareRoot()))
    return a + (b - a) * (t - Double(k))
  }

  /// 縦スクロールバー——印（左 git・中央 検索の一致と語の出現・全幅 キャレット）→ 縁（左と上に 1 デバイス px）→ つまみ。
  func drawVerticalScrollbar(
    _ layout: SurfaceLayout, lines: (first: CGFloat, visible: CGFloat), _ source: Source,
    _ content: SurfaceContent, _ c: Context
  ) {
    let area = layout.verticalScrollbar
    guard area.width > 0, area.height > 0 else { return }
    let g = c.g
    let s = g.scale
    let x0 = (Double(area.minX) * s).rounded()
    let text = content.text
    let ruler = OverviewRuler(
      lineCount: text.lineCount, visibleLines: lines.visible, height: area.height,
      scale: CGFloat(s))
    let palette = c.palette.overview
    updateRulerSpans(ruler, area: area, lines: lines, source, text: text)
    for group in rulerSpans.groups {
      let lane = OverviewRuler.lane(group.kind.lane, width: area.width, scale: CGFloat(s))
      let ink: FrameColor =
        switch group.kind {
        case .added: palette.rulerAdded
        case .modified: palette.rulerModified
        case .removed: palette.rulerRemoved
        case .word: palette.rulerWord
        case .find: palette.rulerFind
        }
      for span in group.spans {
        rect(
          x0 + Double(lane.x), Double(span.y1), Double(lane.width), Double(span.y2 - span.y1), ink)
      }
    }
    let carets = source.material.caret.carets.map {
      NSRange(location: min($0, text.length), length: 0)
    }
    let full = OverviewRuler.lane(.full, width: area.width, scale: CGFloat(s))
    var painted: OverviewRuler.Span?
    for rows in text.rows(ofAscending: carets) {
      let span = ruler.caret(row: rows.lowerBound)
      if let last = painted, span.y1 <= last.y2 {
        painted = OverviewRuler.Span(y1: last.y1, y2: max(last.y2, span.y2))
        continue
      }
      if let last = painted {
        rect(
          x0 + Double(full.x), Double(last.y1), Double(full.width), Double(last.y2 - last.y1),
          palette.rulerCaret)
      }
      painted = span
    }
    if let last = painted {
      rect(
        x0 + Double(full.x), Double(last.y1), Double(full.width), Double(last.y2 - last.y1),
        palette.rulerCaret)
    }
    let width = (Double(area.width) * s).rounded()
    rect(x0, 0, 1, (Double(area.height) * s).rounded(), palette.border)
    rect(x0 + 1, 0, width - 1, 1, palette.border)
  }

  /// 図形を 1 つ足す（px）。
  private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ ink: FrameColor)
  {
    guard width > 0, height > 0 else { return }
    overviewShapes.append(
      ShapeInstance(
        rect: SIMD4(Float(x), Float(y), Float(width), Float(height)), color: ink.packed, radius: 0,
        kind: 0))
  }

  /// 印の縦の区間を、元が変わったときだけ作り直す。検索の一致が多いときは近い行をまとめ、現在の一致を加える。
  private func updateRulerSpans(
    _ ruler: OverviewRuler, area: CGRect, lines: (first: CGFloat, visible: CGFloat),
    _ source: Source, text: TextRope
  ) {
    let highlights = source.material.highlights
    let find = source.rulerRows.find(highlights, text: text)
    let word = source.rulerRows.word(highlights, text: text)
    let marks = source.material.marks
    let key = RulerSpans.Key(
      find: find.generation, word: word.generation, marks: marks, lineCount: text.lineCount,
      visibleLines: lines.visible, height: area.height, scale: ruler.scale,
      current: highlights.crowded ? highlights.current.first : nil)
    guard key != rulerSpans.key else { return }
    rulerSpans.key = key
    var findRows = find.rows
    if highlights.crowded {
      findRows = OverviewRuler.approximate(findRows, lineCount: text.lineCount, height: area.height)
      if let current = highlights.current.first {
        findRows.append(text.rows(of: current))
        findRows.sort { $0.lowerBound < $1.lowerBound }
      }
    }
    let removed = marks.deletions.map { deletion -> ClosedRange<Int> in
      let row = max(0, deletion.row + (deletion.atBottom ? 1 : 0) - 1)
      return row...row
    }
    let groups: [(RulerSpans.Kind, [ClosedRange<Int>])] = [
      (.added, marks.bars.filter { $0.kind == .added }.map(\.rows)),
      (.modified, marks.bars.filter { $0.kind == .modified }.map(\.rows)),
      (.removed, removed),
      (.word, word.rows),
      (.find, findRows),
    ]
    rulerSpans.groups = groups.compactMap { kind, rows in
      rows.isEmpty ? nil : (kind, ruler.spans(rows))
    }
  }
}

extension FrameBuilder {
  /// ミニマップの帯と縦横のスクロールバーのつまみ。濃さはこのコマの時刻から、色は「ドラッグ中・上にポインタ・普段」で、
  /// 上かはこのコマの配置で決める。
  func drawSliders(
    _ layout: SurfaceLayout, lines: (first: CGFloat, visible: CGFloat), _ source: Source,
    lineCount: Int, _ c: Context
  ) {
    let input = source.material.overview
    let motion = source.motion
    let palette = c.palette.overview
    let limits = source.limits
    let x = min(max(0, source.position.x), limits.maximum.x)
    let thumb = motion.thumbOpacity(
      at: source.time,
      state: OverviewMotion.ScrollState(
        first: lines.first, visible: lines.visible, lineCount: lineCount, x: x,
        width: limits.viewport.x, range: limits.maximum.x),
      baselines: source.baselines, input: input, motion: c.config.overview)
    let pointer = input.pointer
    if let placement = minimap.placement {
      let area = layout.minimap
      let over = pointer.map { area.contains($0) } ?? false
      let opacity = motion.sliderOpacity(
        at: source.time, shown: (over || input.drag == .minimap) && placement.sliderNeeded,
        input: input, motion: c.config.overview)
      let hover = pointer.map { over && placement.sliderContains(y: $0.y - area.minY) } ?? false
      let ink =
        input.drag == .minimap
        ? palette.minimapSliderActive : hover ? palette.minimapSliderHover : palette.minimapSlider
      slider(
        CGRect(
          x: area.minX, y: area.minY + placement.sliderTop, width: area.width,
          height: placement.sliderHeight), ink, opacity, c)
    }
    let vertical = layout.verticalScrollbar
    let geometry = ScrollbarGeometry(
      lineCount: lineCount, firstLine: lines.first, visibleLines: lines.visible,
      height: vertical.height)
    if geometry.isNeeded {
      let hover = pointer.map { vertical.contains($0) && geometry.sliderContains($0.y) } ?? false
      slider(
        CGRect(
          x: vertical.minX, y: geometry.sliderPosition, width: vertical.width,
          height: geometry.sliderLength), thumbInk(.vertical, hover, input, palette), thumb, c)
    }
    let horizontal = layout.horizontalScrollbar
    let across = ScrollbarGeometry(
      visible: limits.viewport.x, total: limits.viewport.x + limits.maximum.x, position: x,
      trackLength: horizontal.width)
    if across.isNeeded {
      let hover =
        pointer.map { horizontal.contains($0) && across.sliderContains($0.x - horizontal.minX) }
        ?? false
      slider(
        CGRect(
          x: horizontal.minX + across.sliderPosition, y: horizontal.minY,
          width: across.sliderLength, height: horizontal.height),
        thumbInk(.horizontal, hover, input, palette), thumb, c)
    }
  }

  private func thumbInk(
    _ drag: OverviewInput.Drag, _ hover: Bool, _ input: OverviewInput, _ palette: OverviewPalette
  ) -> FrameColor {
    input.drag == drag ? palette.sliderActive : hover ? palette.sliderHover : palette.slider
  }

  /// 帯・つまみを 1 つ足す（pt の矩形、濃さ `opacity`）。
  private func slider(_ rect: CGRect, _ ink: FrameColor, _ opacity: Double, _ c: Context) {
    guard opacity > 0 else { return }
    let s = c.g.scale
    let left = (Double(rect.minX) * s).rounded()
    let top = (Double(rect.minY) * s).rounded()
    let right = (Double(rect.maxX) * s).rounded()
    let bottom = (Double(rect.maxY) * s).rounded()
    guard right > left, bottom > top else { return }
    overviewShapes.append(
      ShapeInstance(
        rect: SIMD4(Float(left), Float(top), Float(right - left), Float(bottom - top)),
        color: ink.scaled(alpha: opacity), radius: 0, kind: 0))
  }
}

extension FrameColor {
  /// α に `factor` を掛けた色（詰めた値）。
  func scaled(alpha factor: Double) -> UInt32 {
    let alpha = Double(packed >> 24) * min(max(factor, 0), 1)
    return packed & 0x00FF_FFFF | UInt32(alpha.rounded()) << 24
  }
}
