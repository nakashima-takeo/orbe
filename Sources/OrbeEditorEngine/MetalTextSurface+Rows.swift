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
          if case .zone(let zone) = $0.content { return zone }
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
          case .zone(let zone):
            RowLayout.Block(
              line: insertion.line,
              height: Double(max(0, zones[ObjectIdentifier(zone)]?.picture.height ?? 0)),
              content: .zone(ObjectIdentifier(zone)))
          }
        })
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

  /// 今の並びが `insertions` と同じ（境と中身。区画は同一性）か。
  private func holds(_ insertions: [RowInsertion]) -> Bool {
    guard insertions.map(\.line) == rows.boundaries else { return false }
    return zip(insertions, rows.contents).allSatisfy { insertion, content in
      switch (insertion.content, content) {
      case (.lines(let lines), .lines(let texts)): lines.map(\.text) == texts
      case (.zone(let zone), .zone(let id)): ObjectIdentifier(zone) == id
      default: false
      }
    }
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
