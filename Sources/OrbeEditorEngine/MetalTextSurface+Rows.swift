import AppKit
import OrbeEditorCore

/// 縦の並びの差し込みと文書の行の見え方と表示の構成（契約）。並びを変えるのは取引の中だけで、確定するときに見えている先頭の
/// 文書の行を画面の同じ位置に保ち（→ `keepFirstVisibleLine`）、出すときに材料へ書く。
extension MetalTextSurface {
  func setRows(_ rows: SurfaceRows) {
    let insertions = rows.insertions
    guard !holds(insertions) || rows.spans != self.rows.spans else { return }
    precondition(
      insertions.isEmpty || !presentation.showsMinimap, "差し込みはミニマップを出していない面にだけ置く")
    let lineCount = bodySite.sourceContent?.text.lineCount ?? 1
    precondition(
      zip(insertions, insertions.dropFirst()).allSatisfy { $0.line <= $1.line }
        && insertions.allSatisfy { (0...lineCount).contains($0.line) },
      "差し込みの境は昇順で、置く時点の文書の写しの行の範囲（0...行数）に収める")
    precondition(
      zip(rows.spans, rows.spans.dropFirst()).allSatisfy { $0.line < $1.line }
        && rows.spans.allSatisfy { (0..<lineCount).contains($0.line) },
      "区間の始まりは重ならない昇順で、置く時点の文書の写しの行の範囲（0..<行数）に収める")
    let zoneList = insertions.compactMap { insertion -> SurfaceZone? in
      if case .zone(let zone) = insertion.content { return zone }
      return nil
    }
    precondition(
      Set(zoneList.map(ObjectIdentifier.init)).count == zoneList.count, "同じ区画は並びに 1 度だけ置く")
    transact {
      noteRowsChange()
      syncZones(zoneList)
      let lineHeight = Double(config.lineHeight)
      self.rows.replace(
        insertions.map { insertion in
          switch insertion.content {
          case .lines(let lines):
            RowLayout.Block(
              line: insertion.line, height: Double(lines.count) * lineHeight,
              content: .lines(lines))
          case .zone(let zone):
            RowLayout.Block(
              line: insertion.line,
              height: Double(max(0, zones[ObjectIdentifier(zone)]?.picture.height ?? 0)),
              content: .zone(ObjectIdentifier(zone)))
          }
        }, spans: rows.spans)
    }
  }

  func setPresentation(_ presentation: SurfacePresentation) {
    guard presentation != self.presentation else { return }
    precondition(!presentation.showsMinimap || rows.isEmpty, "差し込みのある面ではミニマップを出さない")
    let restyles = presentation.lineStyles != self.presentation.lineStyles
    transact {
      self.presentation = presentation
      let arrangement = SurfaceArrangement(presentation)
      self.arrangement = arrangement
      write { $0.arrangement = arrangement }
      if restyles { appearanceDidChange() }
    }
  }

  /// 今の並びが `insertions` と同じ（境と中身。区画は同一性）か。
  private func holds(_ insertions: [RowInsertion]) -> Bool {
    guard insertions.map(\.line) == rows.boundaries else { return false }
    return zip(insertions, rows.contents).allSatisfy { insertion, content in
      switch (insertion.content, content) {
      case (.lines(let lines), .lines(let laid)): lines == laid
      case (.zone(let zone), .zone(let id)): ObjectIdentifier(zone) == id
      default: false
      }
    }
  }

  /// 並びが `before` から今の並びに変わった——`before` で見えていた先頭の文書の行（塊の上なら次の文書の行）が画面の同じ
  /// 位置に残るよう、縦の位置を差の分だけずらす（まだ出していない置く位置があればそれを、無ければ箱の位置をずらす）。
  /// 見えている高さが無いか、文書の先頭（位置 0）にいれば何もしない——先頭では、文書の先頭に置いた塊をそのまま見せる。
  func keepFirstVisibleLine(from before: RowLayout, lineCount: Int) {
    let (position, limits) = scrollState()
    let top = limits.clampedY(position)
    guard limits.viewport.y > 0, top > 0 else { return }
    let line = before.firstVisibleLine(atY: top, lineCount: lineCount)
    let dy = rows.y(ofLine: line) - before.y(ofLine: line)
    guard dy != 0 else { return }
    if let placed = pending.position {
      pending.position = SIMD2(placed.x, placed.y + dy)
    } else {
      pending.shift += dy
    }
  }
}
