import CoreText

extension ZoneTextLayout {
  /// 字の塊の区切り——余白なしで組んだ行のグリフの文字の位置のうち、書記素の境に当たるもの。結合記号を基底と別のグリフで
  /// 描く字体でも、記号は基底と同じ塊に入る。
  struct Clusters {
    let starts: [Int]
    let end: Int

    init(_ glyphs: [Glyph], _ units: [UInt16]) {
      var boundaries: Set<Int> = []
      var position = 0
      for character in String(decoding: units, as: UTF16.self) {
        boundaries.insert(position)
        position += character.utf16.count
      }
      starts = Set(glyphs.map(\.offset)).intersection(boundaries).sorted()
      end = units.count
    }

    /// 文の位置 `offset` を含む塊（文の範囲）。
    func range(containing offset: Int) -> Range<Int> {
      guard let index = starts.lastIndex(where: { $0 <= offset }) else {
        return 0..<(starts.first ?? end)
      }
      return starts[index]..<(index + 1 < starts.count ? starts[index + 1] : end)
    }
  }

  /// 組んだ行のグリフ 1 つ——見え方（`styles` の添字）・文の位置・x 範囲（行の左端から。置いた余白を含む）。
  struct Glyph {
    let style: Int?
    let offset: Int
    let x: Range<CGFloat>
  }

  /// 組んだ行のグリフ（見た目の左から順に）。
  static func glyphs(of line: CTLine) -> [Glyph] {
    var result: [Glyph] = []
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      let index = style(of: run)
      var positions = [CGPoint](repeating: .zero, count: count)
      var advances = [CGSize](repeating: .zero, count: count)
      var offsets = [CFIndex](repeating: 0, count: count)
      let all = CFRange(location: 0, length: count)
      CTRunGetPositions(run, all, &positions)
      CTRunGetAdvances(run, all, &advances)
      CTRunGetStringIndices(run, all, &offsets)
      for i in 0..<count {
        let lower = positions[i].x
        result.append(
          Glyph(
            style: index, offset: offsets[i],
            x: lower..<max(lower, lower + advances[i].width)))
      }
    }
    return result
  }
}
