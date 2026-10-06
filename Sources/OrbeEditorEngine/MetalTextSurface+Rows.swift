import AppKit
import OrbeEditorCore

/// 縦の並びの差し込みと表示の構成（契約）。並びを変えるのは取引の中だけで、確定するときに見えている先頭の文書の行を画面の
/// 同じ位置に保ち（→ `keepFirstVisibleLine`）、出すときに材料へ書く。
extension MetalTextSurface {
  func setRows(_ rows: SurfaceRows) {
    let insertions = rows.insertions
    guard !holds(insertions) else { return }
    precondition(
      insertions.isEmpty || !presentation.showsMinimap, "差し込みはミニマップを出していない面にだけ置く")
    let lineCount = currentContent?.text.lineCount ?? 1
    precondition(
      zip(insertions, insertions.dropFirst()).allSatisfy { $0.line <= $1.line }
        && insertions.allSatisfy { (0...lineCount).contains($0.line) },
      "差し込みの境は昇順で、写しの行の範囲（0...行数）に収める")
    transact {
      noteRowsChange()
      syncZones(
        insertions.compactMap {
          if case .zone(let view) = $0.content { return view }
          return nil
        })
      let lineHeight = Double(config.lineHeight)
      self.rows.replace(
        insertions.map { insertion in
          switch insertion.content {
          case .lines(let lines):
            RowLayout.Block(
              line: insertion.line, height: Double(lines.count) * lineHeight,
              content: .lines(lines.map(\.text)))
          case .zone(let view):
            RowLayout.Block(
              line: insertion.line, height: zones?.height(of: ObjectIdentifier(view)) ?? 0,
              content: .zone(ObjectIdentifier(view)))
          }
        })
    }
  }

  func remeasureZone(_ view: NSView) {
    transact {
      guard zones?.remeasure(view) == true else { return }
      noteRowsChange()
      applyZoneHeights()
    }
  }

  func setPresentation(_ presentation: SurfacePresentation) {
    guard presentation != self.presentation else { return }
    precondition(!presentation.showsMinimap || rows.isEmpty, "差し込みのある面ではミニマップを出さない")
    transact {
      self.presentation = presentation
      write { $0.showsMinimap = presentation.showsMinimap }
    }
  }

  /// 今の並びが `insertions` と同じ（境と中身。区画は view の同一性）か。
  private func holds(_ insertions: [RowInsertion]) -> Bool {
    guard insertions.map(\.line) == rows.boundaries else { return false }
    return zip(insertions, rows.contents).allSatisfy { insertion, content in
      switch (insertion.content, content) {
      case (.lines(let lines), .lines(let texts)): lines.map(\.text) == texts
      case (.zone(let view), .zone(let id)): ObjectIdentifier(view) == id
      default: false
      }
    }
  }

  /// 取引の中で並びが変わる（取引の前の並びを、見えている先頭の文書の行を保つ起点として覚える）。
  private func noteRowsChange() {
    if transaction?.anchor == nil { transaction?.anchor = rows }
  }

  /// 区画の view を `list` にする（区画が無くなれば置き場ごと外す）。
  private func syncZones(_ list: [NSView]) {
    guard !list.isEmpty else {
      zones?.detach()
      zones = nil
      return
    }
    let zones = zones ?? ZoneViews(surface: self, shadowColor: style.overview.topShadow)
    self.zones = zones
    zones.sync(list, width: surfaceLayout.text.width)
  }

  /// 区画の測った高さで並びを組み直す。
  private func applyZoneHeights() {
    guard let zones else { return }
    let rows = self.rows
    self.rows.replace(
      rows.contents.indices.map { index in
        let content = rows.contents[index]
        var height = rows.heights[index]
        if case .zone(let id) = content { height = zones.height(of: id) }
        return RowLayout.Block(line: rows.boundaries[index], height: height, content: content)
      })
  }

  /// 行の数が `lineCount` の本文の区画の幅が測った幅と違えば区画を測り直し、高さが変われば並びを組み直す（取引の確定の
  /// 中。並びを変えたら true）。
  func refitZones(lineCount: Int) -> Bool {
    let width = config.layout(
      size: size, lineCount: lineCount, showsMinimap: presentation.showsMinimap
    ).text.width
    guard let zones, zones.fit(width: width) else { return false }
    applyZoneHeights()
    return true
  }

  /// 並びが `before` から今の並びに変わった——`before` で見えていた先頭の文書の行（塊の上なら次の文書の行）が画面の同じ
  /// 位置に残るよう、縦の位置を差の分だけずらす（まだ出していない置く位置があればそれを、無ければ箱の位置をずらす）。
  /// 見えている高さが無ければ何もしない。
  func keepFirstVisibleLine(from before: RowLayout, lineCount: Int) {
    let (position, limits) = scrollState()
    guard limits.viewport.y > 0 else { return }
    let line = min(max(0, before.line(atY: limits.clampedY(position))), lineCount - 1)
    let dy = rows.y(ofLine: line) - before.y(ofLine: line)
    guard dy != 0 else { return }
    if let placed = pending.position {
      pending.position = SIMD2(placed.x, placed.y + dy)
    } else {
      pending.shift += dy
    }
  }
}
