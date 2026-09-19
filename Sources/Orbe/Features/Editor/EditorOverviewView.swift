import AppKit
import OrbeEditorCore

/// 本体の右に立つ俯瞰——1px の縁｜ミニマップ（文字を矩形に置き換えた文書の縮図・表示範囲の帯・左端の git 印）｜
/// スクロール印の列（追加／変更の行・キャレットの行）。焦点の文書 1 つに結ばれ、描くときに文書から読む（行数・
/// viewport・選択・ハンク・comment 区間・インデント単位）。「何を描くか」は Core の純関数（`OverviewRows` /
/// `OverviewGeometry` / `LineMarks.runs`）で、ここは面の座標に写すだけ。
///
/// 行の縮図はチャンク単位で覚え、窓に新しく入ったチャンクだけ組む。本文が変われば、編集の行と役割が変わった区間の
/// チャンクを捨て、行が増減したときだけ編集の行より後ろも捨てる（1MB の文書で打鍵ごとに窓ぶんの query を走らせない）。
/// 文書は俯瞰の存在を知らず、pane が「変わった」を配る（`refresh` / `textDidChange`）。ミニマップのクリックはその行を
/// 本文の中央へ。
final class EditorOverviewView: NSView {
  /// 縮図を覚えるチャンクの行数。
  static let chunkLines = 64

  private let style: OverviewStyle
  private(set) weak var document: EditorDocument?
  private var chunks: [Int: [OverviewRow]] = [:]
  /// 覚えているチャンクの行数の前提（行が増減すれば、編集より後ろのチャンクの行番号がずれる）。
  private var cachedLineCount = 0
  /// 覚えているチャンク（テストが捨て方を見る）。
  var cachedChunks: Set<Int> { Set(chunks.keys) }

  init(style: OverviewStyle) {
    self.style = style
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    isHidden = true
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  /// 焦点の文書に結ぶ（nil なら隠す）。
  func bind(_ document: EditorDocument?) {
    self.document = document
    chunks.removeAll()
    cachedLineCount = document?.lineIndex.lineCount ?? 0
    isHidden = document == nil
    needsDisplay = true
  }

  /// viewport・選択・ハンクが変わった。
  func refresh() {
    needsDisplay = true
  }

  /// 本文が変わった。編集の行と役割が変わった区間の縮図を捨て、行が増減していれば編集の行より後ろも捨てる。
  func textDidChange(_ change: TextChange) {
    guard let document else { return }
    let index = document.lineIndex
    let editLine = index.point(at: change.edit.range.location).row
    if index.lineCount != cachedLineCount {
      cachedLineCount = index.lineCount
      let first = editLine / Self.chunkLines
      chunks = chunks.filter { $0.key < first }
    }
    dropChunks(covering: change.edit.newRange, index: index)
    for range in change.changedRoles.rangeView {
      dropChunks(covering: NSRange(range), index: index)
    }
    needsDisplay = true
  }

  private func dropChunks(covering range: NSRange, index: LineIndex) {
    let first = index.point(at: range.location).row / Self.chunkLines
    let last = index.point(at: max(range.location, NSMaxRange(range) - 1)).row / Self.chunkLines
    for chunk in first...last { chunks[chunk] = nil }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  // MARK: - 幾何

  private var minimapRect: NSRect {
    NSRect(x: Theme.Stroke.hairline, y: 0, width: style.minimapWidth, height: bounds.height)
  }

  private var marksRect: NSRect {
    NSRect(x: minimapRect.maxX, y: 0, width: style.marksWidth, height: bounds.height)
  }

  private func geometry(of document: EditorDocument) -> OverviewGeometry {
    let viewport = document.surface.viewport
    let first = CGFloat(document.lineIndex.point(at: viewport.firstVisible).row)
    return OverviewGeometry(
      lineCount: document.lineIndex.lineCount, firstLine: first + viewport.hiddenFraction,
      visibleLines: viewport.visibleLines, pitch: style.pitch,
      height: max(0, bounds.height - style.topInset))
  }

  // MARK: - クリック

  /// 俯瞰の上のホイール／トラックパッドは本文のスクロールへそのまま渡す（縦スクローラーが無いので、右端の列が
  /// スクロールの死角にならないように）。渡す先はテキスト面の view を包む scroll view——AppKit の一般の口だけで、
  /// 面の契約は増やさない。
  override func scrollWheel(with event: NSEvent) {
    guard let scroll = document?.surface.responder.enclosingScrollView else {
      super.scrollWheel(with: event)
      return
    }
    scroll.scrollWheel(with: event)
  }

  override func mouseDown(with event: NSEvent) {
    jump(to: convert(event.locationInWindow, from: nil))
  }

  /// ミニマップの点の下の行を本文の中央へ。ミニマップの外（縁・印の列）では何もしない。
  func jump(to point: NSPoint) {
    guard let document, minimapRect.contains(point) else { return }
    let line = geometry(of: document).line(atY: point.y - style.topInset)
    document.surface.scrollToCenter(document.lineIndex.start(ofRow: line))
  }

  // MARK: - 描く

  override func draw(_ dirtyRect: NSRect) {
    guard let document else { return }
    style.border.setFill()
    NSRect(x: 0, y: 0, width: Theme.Stroke.hairline, height: bounds.height).fill()
    let geometry = geometry(of: document)
    let runs = LineMarks(hunks: document.hunks).runs
    drawBand(geometry)
    drawRows(geometry, document: document)
    drawMinimapMarks(geometry, runs: runs)
    drawScrollMarks(runs: runs, lineCount: geometry.lineCount)
    drawCaretMark(document: document, lineCount: geometry.lineCount)
  }

  /// 帯は上の余白ぶん先頭の行の上へ伸びる（見本は列の上端 0 から始まる）。下端は最後に見えている行の下端。
  private func drawBand(_ geometry: OverviewGeometry) {
    let band = geometry.band
    guard band.height > 0 else { return }
    style.band.setFill()
    let minimap = minimapRect
    backingAlignedRect(
      NSRect(
        x: minimap.minX, y: band.y, width: minimap.width, height: band.height + style.topInset),
      options: .alignAllEdgesNearest
    ).fill()
  }

  private func drawRows(_ geometry: OverviewGeometry, document: EditorDocument) {
    let minimap = minimapRect
    for line in geometry.windowLines {
      let row = row(line, document: document)
      guard row.length > 0 else { continue }
      let y = style.topInset + geometry.y(ofLine: line)
      guard y + style.rowHeight > style.topInset, y < bounds.height else { continue }
      let indent = CGFloat(row.indent) * style.indentWidth
      let width = min(style.maxRowExtent - indent, CGFloat(row.length) * style.columnWidth)
      guard width > 0 else { continue }
      (row.isComment ? style.commentRow : style.row).setFill()
      NSBezierPath(
        roundedRect: NSRect(
          x: minimap.minX + style.leadingInset + indent, y: y, width: width,
          height: style.rowHeight),
        xRadius: style.rowRadius, yRadius: style.rowRadius
      ).fill()
    }
  }

  /// 行の連（1 始まり）をミニマップの y 区間に写し、左端の印を描く。
  private func drawMinimapMarks(_ geometry: OverviewGeometry, runs: [LineMarks.Run]) {
    let minimap = minimapRect
    let column = NSRect(
      x: minimap.minX + style.minimapMarkX, y: style.topInset, width: style.minimapMarkWidth,
      height: max(0, bounds.height - style.topInset))
    for run in runs {
      let top = style.topInset + geometry.y(ofLine: run.lines.lowerBound - 1)
      let bottom = style.topInset + geometry.y(ofLine: run.lines.upperBound - 1)
      let rect = NSRect(x: column.minX, y: top, width: column.width, height: bottom - top)
        .intersection(column)
      guard !rect.isEmpty else { continue }
      (run.kind == .added ? style.minimapAdded : style.minimapModified).setFill()
      backingAlignedRect(rect, options: .alignAllEdgesNearest).fill()
    }
  }

  /// 印の列は文書比例。
  private func drawScrollMarks(runs: [LineMarks.Run], lineCount: Int) {
    let marks = marksRect
    for run in runs {
      let mark = OverviewGeometry.proportional(
        lines: (run.lines.lowerBound - 1)..<(run.lines.upperBound - 1), of: lineCount,
        height: marks.height, minimum: style.rowHeight)
      (run.kind == .added ? style.marksAdded : style.marksModified).setFill()
      backingAlignedRect(
        NSRect(
          x: marks.minX + style.marksBarX, y: mark.y, width: style.marksBarWidth,
          height: mark.height),
        options: .alignAllEdgesNearest
      ).fill()
    }
  }

  private func drawCaretMark(document: EditorDocument, lineCount: Int) {
    let marks = marksRect
    let row = document.lineIndex.point(at: document.surface.selectedRange.location).row
    let mark = OverviewGeometry.proportional(
      lines: row..<(row + 1), of: lineCount, height: marks.height, minimum: style.caretMarkHeight)
    style.caret.setFill()
    backingAlignedRect(
      NSRect(
        x: marks.minX + style.caretMarkX, y: mark.y, width: style.caretMarkWidth,
        height: style.caretMarkHeight),
      options: .alignAllEdgesNearest
    ).fill()
  }

  // MARK: - 縮図のキャッシュ

  private func row(_ line: Int, document: EditorDocument) -> OverviewRow {
    let chunk = line / Self.chunkLines
    if let rows = chunks[chunk] { return rows[line - chunk * Self.chunkLines] }
    let index = document.lineIndex
    let lines = (chunk * Self.chunkLines)..<min((chunk + 1) * Self.chunkLines, index.lineCount)
    let range = NSRange(
      location: index.start(ofRow: lines.lowerBound),
      length: index.end(ofRow: lines.upperBound - 1) - index.start(ofRow: lines.lowerBound))
    let rows = OverviewRows.rows(
      lines: lines, text: document.surface.substring(in: range), index: index,
      tabWidth: document.indentUnit, commentRanges: document.commentRanges(in: range))
    chunks[chunk] = rows
    return rows[line - lines.lowerBound]
  }
}
