import AppKit
import OrbeEditorCore

/// 縦の並びの差し込みと文書の行の見え方と表示の構成（契約）。並びを変えるのは取引の中だけで、確定するときに見えている先頭の
/// 文書の行を画面の同じ位置に保ち（→ `keepFirstVisibleLine`）、出すときに材料へ書く。
extension MetalTextSurface {
  func setRows(_ rows: SurfaceRows) {
    let insertions = rows.insertions
    guard !holds(insertions) || rows.spans != self.rows.spans || rows.source !== rowSource else {
      return
    }
    precondition(
      insertions.isEmpty || !presentation.showsMinimap, "差し込みはミニマップを出していない面にだけ置く")
    // 差し込みの多い並び（1MB の diff で数千）を打鍵のたびに置き直しうるので、契約の検査は 1 回の走査で一時の列を作らずに行う。
    let lineCount = bodySite.sourceContent?.text.lineCount ?? 1
    precondition(
      Self.boundariesAreValid(insertions, lineCount: lineCount),
      "差し込みの境は昇順で、置く時点の文書の写しの行の範囲（0...行数）に収める")
    precondition(
      Self.spansAreValid(rows.spans, lineCount: lineCount),
      "区間の始まりは重ならない昇順で、置く時点の文書の写しの行の範囲（0..<行数）に収める")
    let sourceContent = rows.source?.rowSourceContent
    let sourceLines = sourceContent?.text.lineCount ?? 0
    precondition(
      Self.insertedLinesAreValid(insertions, sourceLines: sourceLines),
      "差し込んだ行が指す行は、出どころの写しの行の範囲（0..<行数）に収める")
    var zoneList: [SurfaceZone] = []
    var zoneIDs = Set<ObjectIdentifier>()
    var zonesAreUnique = true
    for insertion in insertions {
      guard case .zone(let zone) = insertion.content else { continue }
      zoneList.append(zone)
      if !zoneIDs.insert(ObjectIdentifier(zone)).inserted { zonesAreUnique = false }
    }
    precondition(zonesAreUnique, "同じ絵の差し込みは並びに 1 度だけ置く")
    transact {
      noteRowsChange()
      rowSource = rows.source
      write { $0.rowSourceContent = sourceContent }
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

  /// 出どころの役割が変わった。写しを引き直して材料に置く（差し込んだ行の色は描くたびに写しから引くので、置けば描き直る）。
  func rowSourceRolesDidChange(_ ranges: IndexSet) {
    guard let content = rowSource?.rowSourceContent else { return }
    write { $0.rowSourceContent = content }
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

  /// 差し込みの境が昇順で、どれも 0...`lineCount` に収まる。
  private static func boundariesAreValid(_ insertions: [RowInsertion], lineCount: Int) -> Bool {
    var previous = Int.min
    for insertion in insertions {
      guard previous <= insertion.line, (0...lineCount).contains(insertion.line) else {
        return false
      }
      previous = insertion.line
    }
    return true
  }

  /// 区間の始まりが重ならない昇順で、どれも 0..<`lineCount` に収まる。
  private static func spansAreValid(_ spans: [LineSpan], lineCount: Int) -> Bool {
    var previous = Int.min
    for span in spans {
      guard previous < span.line, (0..<lineCount).contains(span.line) else { return false }
      previous = span.line
    }
    return true
  }

  /// 差し込んだ行が指す行（指していれば）が、どれも出どころの 0..<`sourceLines` に収まる。
  private static func insertedLinesAreValid(_ insertions: [RowInsertion], sourceLines: Int) -> Bool
  {
    for insertion in insertions {
      guard case .lines(let lines) = insertion.content else { continue }
      for inserted in lines {
        if let line = inserted.line, !(0..<sourceLines).contains(line) { return false }
      }
    }
    return true
  }

  /// 今の並びが `insertions` と同じ（境と中身。絵の差し込みは同一性）か。
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
