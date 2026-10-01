import CoreGraphics
import OrbeEditorCore

/// 面の区画の配置（VS Code の `EditorLayoutInfo`）——左から行番号の列（行番号と git の印の列）｜本文の区画｜ミニマップ｜
/// 縦スクロールバー、本文の区画の下端に横スクロールバーが重なる。ミニマップの幅は VS Code の式（Core の
/// `MinimapLayout.width`）に面の実の行番号の列の幅を入れて出す。当たり・自動スクロールの境・見せるところまで・見えて
/// いる範囲・IME の文字の矩形・切り取りは、どれもこの 1 つの配置を使う（描いた位置と当たりが食い違わない）。座標は面の
/// view の pt（左上が原点、y は下向き）。
struct SurfaceLayout: Equatable, Sendable {
  let size: CGSize
  /// 行番号の列の幅（行番号と git の印の列）。
  let column: CGFloat
  let minimapWidth: CGFloat
  let scrollbarWidth: CGFloat
  let horizontalScrollbarHeight: CGFloat

  init(size: CGSize, column: CGFloat, cell: CGFloat, overview: SurfaceConfig.Overview) {
    self.size = size
    self.column = column
    let scrollbar = min(overview.scrollbarWidth, max(0, size.width))
    let minimap = MinimapLayout.width(
      remaining: size.width - column, charWidth: cell, scrollbar: overview.scrollbarWidth,
      maxWidth: overview.minimapMaxWidth)
    scrollbarWidth = scrollbar
    minimapWidth = max(0, min(max(0, size.width), minimap + overview.scrollbarWidth) - scrollbar)
    horizontalScrollbarHeight = overview.horizontalScrollbarHeight
  }

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

  /// 大きさ `size`・行の数 `lineCount` の面の区画の配置。
  func layout(size: CGSize, lineCount: Int) -> SurfaceLayout {
    SurfaceLayout(
      size: size, column: columnWidth(lineCount: lineCount), cell: cell, overview: overview)
  }
}

extension MetalTextSurface: OverviewDrawingSurface {
  var rightColumnWidth: CGFloat { surfaceLayout.rightColumnWidth }
}
