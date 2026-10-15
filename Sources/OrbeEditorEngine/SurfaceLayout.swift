import CoreGraphics
import OrbeEditorCore

/// 面の区画の配置（VS Code の `EditorLayoutInfo`）——左から行番号の列（番号の列・git の印の列・記号の列）｜本文の区画｜
/// ミニマップ｜縦スクロールバー、本文の区画の下端に横スクロールバーが重なる。ミニマップの幅は VS Code の式（Core の
/// `MinimapLayout.width`）に面の実の行番号の列の幅を入れて出す。ミニマップを出さない構成では、右列は縦スクロールバー
/// だけ。当たり・自動スクロールの境・見せるところまで・見えている範囲・IME の文字の矩形・切り取りは、どれもこの 1 つの
/// 配置を使う（描いた位置と当たりが食い違わない）。座標は面の view の pt（左上が原点、y は下向き）。
struct SurfaceLayout: Equatable, Sendable {
  let size: CGSize
  /// 行番号の列の中の配置。
  let gutter: GutterColumns
  let minimapWidth: CGFloat
  let scrollbarWidth: CGFloat
  let horizontalScrollbarHeight: CGFloat

  init(
    size: CGSize, gutter: GutterColumns, cell: CGFloat, overview: SurfaceConfig.Overview,
    showsMinimap: Bool
  ) {
    self.size = size
    self.gutter = gutter
    let column = gutter.width
    let scrollbar = min(overview.scrollbarWidth, max(0, size.width))
    scrollbarWidth = scrollbar
    if showsMinimap {
      let minimap = MinimapLayout.width(
        remaining: size.width - column, charWidth: cell, scrollbar: overview.scrollbarWidth,
        maxWidth: overview.minimapMaxWidth)
      minimapWidth = max(
        0, min(max(0, size.width), minimap + overview.scrollbarWidth) - scrollbar)
    } else {
      minimapWidth = 0
    }
    horizontalScrollbarHeight = overview.horizontalScrollbarHeight
  }

  /// 行番号の列の幅。
  var column: CGFloat { gutter.width }

  /// 右列（ミニマップ＋縦スクロールバー）の幅。
  var rightColumnWidth: CGFloat { minimapWidth + scrollbarWidth }

  /// 本文の区画（行番号の列の右からミニマップの左まで、上から下まで）。
  var text: CGRect {
    CGRect(
      x: column, y: 0, width: max(0, size.width - column - rightColumnWidth), height: size.height)
  }

  var minimap: CGRect {
    CGRect(
      x: size.width - rightColumnWidth, y: 0, width: minimapWidth, height: size.height)
  }

  var verticalScrollbar: CGRect {
    CGRect(x: size.width - scrollbarWidth, y: 0, width: scrollbarWidth, height: size.height)
  }

  /// 横スクロールバー（本文の区画の下端に重なる。本文の見えている高さは削らない——VS Code と同じく最終行の先まで送れる
  /// ので、下端の行も送れば見える）。
  var horizontalScrollbar: CGRect {
    let text = self.text
    return CGRect(
      x: text.minX, y: max(0, size.height - horizontalScrollbarHeight), width: text.width,
      height: min(horizontalScrollbarHeight, size.height))
  }
}

extension SurfaceConfig {
  /// 俯瞰の寸法と時間（見え方の値のうち、色でないもの）。
  struct Overview: Sendable {
    var scrollbarWidth: CGFloat
    var horizontalScrollbarHeight: CGFloat
    var minimapMaxWidth: CGFloat
    var fadeIn: Double
    var fadeOut: Double
    var hideDelay: Double

    init(_ style: TextSurfaceStyle.Overview) {
      scrollbarWidth = style.scrollbar.width
      horizontalScrollbarHeight = style.scrollbar.horizontalHeight
      minimapMaxWidth = style.minimap.maxWidth
      fadeIn = style.fadeIn
      fadeOut = style.fadeOut
      hideDelay = style.hideDelay
    }
  }

  /// 大きさ `size`・行の数 `lineCount`・縦の並び `rows`（2 列の面の左の列の番号）・配置の構成 `arrangement` の面の区画の
  /// 配置。
  func layout(
    size: CGSize, lineCount: Int, rows: RowLayout, arrangement: SurfaceArrangement
  ) -> SurfaceLayout {
    SurfaceLayout(
      size: size, gutter: gutter(lineCount: lineCount, rows: rows, arrangement: arrangement),
      cell: cell, overview: overview, showsMinimap: arrangement.showsMinimap)
  }

  /// 行番号の列の配置。番号の列はどれも、最小の幅か、列の最大の番号が右の余白を残して収まる幅の広い方（最小の幅と余白は
  /// 構成が持てば構成の、無ければ見え方の値）。
  func gutter(lineCount: Int, rows: RowLayout, arrangement: SurfaceArrangement) -> GutterColumns {
    let minimum = arrangement.numberWidth ?? gutterWidth
    let trailing = arrangement.numberTrailing ?? gutterTrailingInset
    let width = { (number: Int) in
      max(minimum, ceil(self.numberWidth(max(1, number))) + trailing)
    }
    return GutterColumns(
      own: width(lineCount),
      other: arrangement.numberColumns == 2
        ? width(rows.otherNumberMax(lineCount: lineCount)) : nil,
      marks: arrangement.showsMarks ? marks.gutterWidth : 0, sign: arrangement.signWidth,
      trailing: trailing)
  }
}

/// 表示の構成のうち、配置と描き方に効くもの（行の型の色は `FramePalette.lineStyles`）。
struct SurfaceArrangement: Equatable, Sendable {
  var showsMinimap = true
  var numberColumns = 1
  var numberWidth: CGFloat?
  var numberTrailing: CGFloat?
  var signWidth: CGFloat = 0
  var showsMarks = true

  init() {}

  init(_ presentation: SurfacePresentation) {
    showsMinimap = presentation.showsMinimap
    numberColumns = presentation.numberColumns
    numberWidth = presentation.numberWidth
    numberTrailing = presentation.numberTrailing
    signWidth = presentation.signWidth
    showsMarks = presentation.showsMarks
  }
}

/// 行番号の列の中の配置（pt）。左から 番号の列（2 列ならもう一方の番号・文書の行の番号）｜git の印の列｜記号の列。位置は
/// 列の右端からの距離で持つ（行番号の数字は右寄せ）。
struct GutterColumns: Equatable, Sendable {
  /// 文書の行の番号の列と、もう一方の番号の列（1 列なら nil）の幅。
  let own: CGFloat
  let other: CGFloat?
  /// git の印の列（持たなければ 0）と記号の列の幅。
  let marks: CGFloat
  let sign: CGFloat
  /// 番号の右端と列の右端の間。
  let trailing: CGFloat

  /// 行番号の列の幅。
  var width: CGFloat { (other ?? 0) + own + marks + sign }

  /// 番号の列の右端（印の列の左端）の、列の右端からの距離。
  var numbersInset: CGFloat { marks + sign }

  /// 文書の行の番号・もう一方の番号の右端の、列の右端からの距離。
  var ownInset: CGFloat { sign + marks + trailing }
  var otherInset: CGFloat { sign + marks + own + trailing }
}

extension MetalTextSurface {
  var rightColumnWidth: CGFloat { surfaceLayout.rightColumnWidth }
}
