import Foundation

/// タブ行 1 回ぶんの投影。セル（タブ 1 枚の描画に要るもの）とセグメント構造を 1 つの値にまとめ、
/// `StatusRowView` はこの値だけを辿る。タブ集合とセグメント構造を別々の observable に置くと、
/// 入れ子 ForEach の子更新が古い構造で新しい集合を引く窓ができる（別々に代入される以上、
/// View が両方を別々に読む構造そのものが不整合を持つ）。controller が `SessionStore.segments(of:)`
/// から組んで `StatusRowModel.strip` へ 1 回で代入し、幅計算もこの値から出す。
struct TabStrip: Equatable {
  /// タブ 1 枚。`index` は平坦なタブ index（`active`・`editingIndex`・`onSelect` と同じ空間）で、
  /// 連の順に 0 から連番＝`cells` の位置と一致する（組み手が保証する）。
  struct Cell: Equatable, Identifiable {
    let index: Int
    let title: String
    let glyph: AgentStateIcon.Kind?
    /// タブの同一性（`TerminalTab.id`）。流し込まないホスト（gallery 等）では nil。
    let tabId: Int?
    var id: Int { index }
  }

  /// 隣接する同 worktree のタブの連。
  struct Segment: Equatable {
    let cells: [Cell]
    /// worktree 識別色番号（`Color.theme.worktreeBar` の index）。
    let colorIndex: Int
    /// 2 枚以上の連＝左端に識別バー・各セル左に区切り線。
    var bar: Bool { cells.count >= 2 }
    var range: Range<Int> { (cells.first?.index ?? 0)..<((cells.last?.index ?? -1) + 1) }
  }

  var segments: [Segment] = []

  var cells: [Cell] { segments.flatMap(\.cells) }
  var count: Int { segments.reduce(0) { $0 + $1.cells.count } }
  var ranges: [Range<Int>] { segments.map(\.range) }
  var colorIndices: [Int] { segments.map(\.colorIndex) }
  var titles: [String] { cells.map(\.title) }
  var glyphs: [AgentStateIcon.Kind?] { cells.map(\.glyph) }
  var tabIds: [Int?] { cells.map(\.tabId) }

  init(segments: [Segment] = []) {
    self.segments = segments
  }

  /// 平坦な列から組む。`segments` を渡さないホスト（gallery 等）は全タブ単独。
  init(
    titles: [String], glyphs: [AgentStateIcon.Kind?] = [], tabIds: [Int] = [],
    segments: [Range<Int>]? = nil, colorIndices: [Int] = []
  ) {
    let ranges = segments ?? StatusTabLayout.singletons(count: titles.count)
    self.segments = ranges.enumerated().map { s, r in
      Segment(
        cells: r.map { i in
          Cell(
            index: i, title: titles[i],
            glyph: glyphs.indices.contains(i) ? glyphs[i] : nil,
            tabId: tabIds.indices.contains(i) ? tabIds[i] : nil)
        },
        colorIndex: colorIndices.indices.contains(s) ? colorIndices[s] : 0)
    }
  }
}
